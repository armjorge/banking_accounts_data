import { createHash } from "node:crypto";
import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import pg from "pg";

const ssm = new SSMClient({});
const s3 = new S3Client({});
const RETENTION_DAYS = 365;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const ID_RE = /^\d{1,18}$/;

interface HttpEvent {
  rawPath?: string;
  body?: string | null;
  queryStringParameters?: Record<string, string | undefined> | null;
  requestContext?: {
    http?: { method?: string };
    authorizer?: { jwt?: { claims?: Record<string, string | undefined> } };
  };
}

interface HttpResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

interface PgError {
  code: string;
  message: string;
}

interface UploadPayload {
  upload_id?: string;
  tenant_id?: string;
  curated_csv_backup?: boolean;
  row_count?: number;
  file_suffix?: string;
  vault_key?: string;
  vault_metadata?: Record<string, string>;
  vault_manifest_key?: string;
  vault_manifest?: Record<string, unknown>;
}

// sql/013: write-once object under the curated prefix (Object Lock governance).
async function putVaultObject(
  key: string,
  body: Buffer | string,
  contentType: string,
  metadata?: Record<string, string>,
): Promise<void> {
  const retainUntil = new Date(Date.now() + RETENTION_DAYS * 24 * 60 * 60 * 1000);
  await s3.send(
    new PutObjectCommand({
      Bucket: process.env.CURATED_BUCKET,
      Key: key,
      Body: body,
      ContentType: contentType,
      Metadata: metadata,
      IfNoneMatch: "*",
      ObjectLockMode: "GOVERNANCE",
      ObjectLockRetainUntilDate: retainUntil,
    }),
  );
}

function json(statusCode: number, body: unknown): HttpResult {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

function connectableUrl(url: string): string {
  const parsed = new URL(url);
  parsed.searchParams.delete("channel_binding");
  if (!parsed.searchParams.get("sslmode")) {
    parsed.searchParams.set("sslmode", "require");
  }
  return parsed.toString();
}

async function neonUrl(): Promise<string> {
  const name = process.env.NEON_URL_PARAM;
  if (!name) {
    throw new Error("NEON_URL_PARAM is not set");
  }
  const result = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  const value = result.Parameter?.Value;
  if (!value) {
    throw new Error("Neon URL parameter is empty");
  }
  return connectableUrl(value);
}

function isPgError(error: unknown): error is PgError {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    "message" in error &&
    typeof error.code === "string" &&
    typeof error.message === "string"
  );
}

function mapError(error: unknown): HttpResult {
  if (isPgError(error)) {
    if (error.code === "23505") {
      const message = error.message.toLowerCase().includes("already uploaded")
        ? "already uploaded"
        : error.message;
      return json(409, { error: message });
    }
    if (["23514", "22023", "22P02", "22007", "P0002", "42501", "28000"].includes(error.code)) {
      return json(400, { error: error.message });
    }
  }
  console.error("statements request failed", error);
  return json(500, { error: "Could not update the statements." });
}

function asDate(value: unknown): string | null {
  if (typeof value !== "string" || !DATE_RE.test(value)) {
    return null;
  }
  return value;
}

function asObject(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) {
    return {};
  }
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {};
  }
  return parsed as Record<string, unknown>;
}

async function withSession<T>(
  claims: Record<string, string | undefined>,
  run: (client: pg.Client) => Promise<T>,
): Promise<T> {
  const sub = claims.sub;
  const email = claims.email;
  if (!sub || !email) {
    throw new Error("missing identity");
  }
  const client = new pg.Client({
    connectionString: await neonUrl(),
    ssl: { rejectUnauthorized: true },
  });
  await client.connect();
  try {
    const user = await client.query<{ user_id: string }>(
      `INSERT INTO cognito_users.users (cognito_sub, email)
       VALUES ($1, $2)
       ON CONFLICT (cognito_sub) DO UPDATE SET email = EXCLUDED.email
       RETURNING user_id::text`,
      [sub, email],
    );
    const userId = user.rows[0]?.user_id;
    if (!userId) {
      throw new Error("cognito user was not stored");
    }
    const tenant = await client.query<{ ensure_personal_tenant: string }>(
      "SELECT public.ensure_personal_tenant($1::uuid)::text",
      [userId],
    );
    const tenantId = tenant.rows[0]?.ensure_personal_tenant;
    if (!tenantId) {
      throw new Error("tenant was not stored");
    }
    await client.query("BEGIN");
    try {
      await client.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
      await client.query("SET LOCAL ROLE strm_app");
      const result = await run(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }
  } finally {
    await client.end();
  }
}

export async function handler(event: HttpEvent): Promise<HttpResult> {
  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  if (!claims.sub) {
    return json(401, { error: "Sign in required" });
  }
  const method = event.requestContext?.http?.method ?? "GET";
  const path = (event.rawPath ?? "").replace(/\/+$/, "") || "/";
  try {
    return await dispatch(claims, method, path, event);
  } catch (error) {
    if (error instanceof SyntaxError) {
      return json(400, { error: "The request body is not valid JSON." });
    }
    if (error instanceof Error && error.message === "missing identity") {
      return json(401, { error: "Sign in required" });
    }
    return mapError(error);
  }
}

async function dispatch(
  claims: Record<string, string | undefined>,
  method: string,
  path: string,
  event: HttpEvent,
): Promise<HttpResult> {
  if (method === "GET" && path === "/statements") {
    const asOf = asDate(event.queryStringParameters?.as_of ?? "");
    const home = await withSession(claims, async (client) => {
      const result = asOf
        ? await client.query("SELECT public.statement_home($1::date)", [asOf])
        : await client.query("SELECT public.statement_home(CURRENT_DATE)");
      // sql/016: upload completeness for the same day as the home.
      const completeness = await client.query(
        "SELECT public.upload_completeness(COALESCE($1::date, CURRENT_DATE))",
        [asOf],
      );
      return { ...(result.rows[0]?.statement_home ?? {}), completeness: completeness.rows[0]?.upload_completeness };
    });
    return json(200, home ?? {});
  }

  // sql/015: dimensions page.
  if (method === "GET" && path === "/dimensions") {
    const summary = await withSession(claims, async (client) => {
      const result = await client.query("SELECT public.dimension_summary()");
      return result.rows[0]?.dimension_summary;
    });
    return json(200, summary ?? {});
  }

  if (method === "GET" && path === "/dimensions/rows") {
    const params = event.queryStringParameters ?? {};
    const limit = Number.parseInt(params.limit ?? "200", 10);
    const offset = Number.parseInt(params.offset ?? "0", 10);
    const rows = await withSession(claims, async (client) => {
      const result = await client.query(
        "SELECT public.dimension_rows($1, $2, $3::date, $4::date, $5, $6, $7)",
        [
          params.kind ?? null,
          params.layer ?? null,
          asDate(params.from ?? ""),
          asDate(params.to ?? ""),
          typeof params.q === "string" ? params.q.slice(0, 100) : null,
          Number.isFinite(limit) ? limit : 200,
          Number.isFinite(offset) ? offset : 0,
        ],
      );
      return result.rows[0]?.dimension_rows;
    });
    return json(200, rows ?? {});
  }

  if (method === "POST" && path === "/dimensions") {
    const body = asObject(event.body);
    const text = (value: unknown): string | null => (typeof value === "string" ? value : null);
    // sql/016: {row_hash, values: {attribute_1: "text" | {item_id} | {new_item} | null, ...}}
    if (body.values && typeof body.values === "object" && !Array.isArray(body.values)) {
      const saved = await withSession(claims, async (client) => {
        const result = await client.query("SELECT public.save_dimension_values($1, $2::jsonb)", [
          text(body.row_hash),
          JSON.stringify(body.values),
        ]);
        return result.rows[0]?.save_dimension_values;
      });
      return json(200, saved ?? {});
    }
    const saved = await withSession(claims, async (client) => {
      const result = await client.query("SELECT public.save_dimension($1, $2, $3, $4)", [
        text(body.row_hash),
        text(body.attribute_1),
        text(body.attribute_2),
        text(body.attribute_3),
      ]);
      return result.rows[0]?.save_dimension;
    });
    return json(200, saved ?? {});
  }

  // sql/015: read-only API tokens for Google Sheets, with the plan's API usage.
  if (method === "GET" && path === "/api-tokens") {
    const listed = await withSession(claims, async (client) => {
      const result = await client.query("SELECT public.list_api_tokens() AS tokens, public.api_usage_summary() AS usage");
      return result.rows[0];
    });
    return json(200, { tokens: listed?.tokens ?? [], usage: listed?.usage ?? {} });
  }

  if (method === "POST" && path === "/api-tokens") {
    const body = asObject(event.body);
    const created = await withSession(claims, async (client) => {
      const result = await client.query("SELECT public.create_api_token($1)", [
        typeof body.token_name === "string" ? body.token_name : null,
      ]);
      return result.rows[0]?.create_api_token;
    });
    return json(200, created ?? {});
  }

  const tokenRevoke = path.match(/^\/api-tokens\/([^/]+)$/);
  if (method === "DELETE" && tokenRevoke) {
    if (!UUID_RE.test(tokenRevoke[1])) {
      return json(400, { error: "token id is not valid" });
    }
    const revoked = await withSession(claims, async (client) => {
      const result = await client.query("SELECT public.revoke_api_token($1::uuid)", [tokenRevoke[1]]);
      return result.rows[0]?.revoke_api_token;
    });
    return json(200, revoked ?? {});
  }

  const sql016 = await dispatch016(claims, method, path, event);
  if (sql016) {
    return sql016;
  }

  const sql017 = await dispatch017(claims, method, path, event);
  if (sql017) {
    return sql017;
  }

  const sql018 = await dispatch018(claims, method, path, event);
  if (sql018) {
    return sql018;
  }

  if (method === "POST" && path === "/accounts") {
    const body = asObject(event.body);
    const asOf = asDate(body.as_of);
    const accountId = await withSession(claims, async (client) => {
      const result = await client.query<{ create_bank_account: number }>(
        `SELECT public.create_bank_account($1, $2, $3, $4, $5, $6, COALESCE($7::date, CURRENT_DATE))`,
        [
          body.bank_id,
          body.a_type_id,
          body.account_name,
          body.account_number,
          body.account_cutoff_day ?? null,
          body.credit_days ?? null,
          asOf,
        ],
      );
      return result.rows[0]?.create_bank_account;
    });
    return json(200, { account_id: accountId });
  }

  const cutoffEdit = path.match(/^\/accounts\/(\d+)\/cutoff$/);
  if (method === "POST" && cutoffEdit) {
    // sql/012: change a credit card's cutoff day and payment window.
    const body = asObject(event.body);
    const asOf = asDate(body.as_of);
    const result = await withSession(claims, async (client) => {
      const updated = await client.query<{ update_bank_account_cutoff: unknown }>(
        `SELECT public.update_bank_account_cutoff($1, $2, $3, COALESCE($4::date, CURRENT_DATE))`,
        [Number(cutoffEdit[1]), body.account_cutoff_day ?? null, body.credit_days ?? null, asOf],
      );
      return updated.rows[0]?.update_bank_account_cutoff;
    });
    return json(200, result ?? {});
  }

  if (method === "POST" && path === "/periods") {
    const body = asObject(event.body);
    const asOf = asDate(body.as_of);
    const cutoffId = await withSession(claims, async (client) => {
      const result = await client.query<{ add_earlier_period: number }>(
        `SELECT public.add_earlier_period($1, COALESCE($2::date, CURRENT_DATE))`,
        [body.account_id, asOf],
      );
      return result.rows[0]?.add_earlier_period;
    });
    return json(200, { cutoff_id: cutoffId });
  }

  const periodDelete = path.match(/^\/periods\/(\d+)$/);
  if (method === "DELETE" && periodDelete) {
    const asOf = asDate(event.queryStringParameters?.as_of ?? "");
    await withSession(claims, async (client) => {
      await client.query(`SELECT public.remove_statement_period($1, COALESCE($2::date, CURRENT_DATE))`, [
        Number(periodDelete[1]),
        asOf,
      ]);
    });
    return json(200, { ok: true });
  }

  if (method === "POST" && path === "/uploads") {
    const body = asObject(event.body);
    const slot = typeof body.slot === "string" ? body.slot : "statement";
    const filename = typeof body.filename === "string" ? body.filename : "";
    // sql/013: the name the user picked is stored as-is; filename is the working CSV name.
    const chosenFilename = typeof body.chosen_filename === "string" ? body.chosen_filename : filename;
    const asOf = asDate(body.as_of);
    const pdfBase64 = typeof body.pdf_base64 === "string" ? body.pdf_base64 : "";
    const csv = typeof body.csv === "string" ? body.csv : "";
    const encoding = typeof body.encoding === "string" ? body.encoding : null;
    const delimiter = typeof body.delimiter === "string" ? body.delimiter : null;
    // sql/018 column map wizard: sent only when the file matched no profile or saved map.
    const columnMap =
      body.mapping && typeof body.mapping === "object" && !Array.isArray(body.mapping)
        ? JSON.stringify(body.mapping)
        : null;
    const templateName = typeof body.template_name === "string" ? body.template_name : null;
    if (slot === "pdf") {
      if (!pdfBase64 || pdfBase64.length > 3_000_000) {
        return json(400, { error: "The PDF is empty or larger than 2 MB" });
      }
    } else if (!csv || csv.length > 2_000_000) {
      return json(400, { error: "The statement file is empty or larger than 2 MB" });
    }
    const ingested = await withSession(claims, async (client) => {
      const result =
        slot === "pdf"
          ? await client.query(
              `SELECT public.ingest_period_pdf_upload($1, $2, $3, $4, $5, COALESCE($6::date, CURRENT_DATE))`,
              [body.account_id, body.cutoff_id, filename, chosenFilename, pdfBase64, asOf],
            )
          : await client.query(
              `SELECT public.ingest_statement_upload($1, $2, $3, $4, $5, $6, COALESCE($7::date, CURRENT_DATE), $8, $9, $10::jsonb, $11)`,
              [
                body.account_id,
                body.cutoff_id,
                slot,
                filename,
                chosenFilename,
                csv,
                asOf,
                encoding,
                delimiter,
                columnMap,
                templateName,
              ],
            );
      const row = result.rows[0] as
        | { ingest_statement_upload?: UploadPayload; ingest_period_pdf_upload?: UploadPayload }
        | undefined;
      return row?.ingest_statement_upload ?? row?.ingest_period_pdf_upload;
    });
    const payload = ingested ?? {};
    // The manifest and metadata are for the vault only; the page does not need them.
    const { vault_metadata: vaultMetadata, vault_manifest: vaultManifest, vault_manifest_key: manifestKey, ...reply } =
      payload;
    if (payload.curated_csv_backup && payload.upload_id && payload.tenant_id && process.env.CURATED_BUCKET) {
      try {
        const suffix = payload.file_suffix === "pdf" ? "pdf" : "csv";
        // Vault name from sql/013: curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{ext}.
        const key = payload.vault_key;
        if (!key || !key.startsWith(`curated/${payload.tenant_id}/`)) {
          throw new Error("vault key missing from ingest result");
        }
        const bodyBytes = suffix === "pdf" ? Buffer.from(pdfBase64, "base64") : Buffer.from(csv, "utf8");
        const objectSha256 = createHash("sha256").update(bodyBytes).digest("hex");
        await putVaultObject(key, bodyBytes, suffix === "pdf" ? "application/pdf" : "text/csv; charset=utf-8", {
          ...(vaultMetadata ?? {}),
          "object-sha256": objectSha256,
        });
        await withSession(claims, async (client) => {
          await client.query("SELECT public.attach_curated_backup($1::uuid, $2)", [
            payload.upload_id,
            key,
          ]);
        });
        let manifestWarning: string | undefined;
        if (manifestKey && vaultManifest) {
          try {
            const manifest = { ...vaultManifest, object_sha256: objectSha256, object_size: bodyBytes.length };
            await putVaultObject(manifestKey, JSON.stringify(manifest, null, 1), "application/json");
          } catch (error) {
            console.error("vault manifest failed", error);
            manifestWarning = "The file was saved in the vault, but its manifest could not be written.";
          }
        }
        return json(200, { ...reply, curated_s3_key: key, ...(manifestWarning ? { backup_warning: manifestWarning } : {}) });
      } catch (error) {
        console.error("curated backup failed", error);
        return json(200, {
          ...reply,
          backup_warning: "The working file was saved. The curated backup could not be written.",
        });
      }
    }
    return json(200, reply);
  }

  const uploadDelete = path.match(/^\/uploads\/([^/]+)$/);
  if (method === "DELETE" && uploadDelete) {
    const uploadId = uploadDelete[1];
    if (!UUID_RE.test(uploadId)) {
      return json(400, { error: "upload id is not valid" });
    }
    const marker = await withSession(claims, async (client) => {
      // sql/013: the vault object stays; a delete marker tells a rebuild it was removed.
      const found = await client.query<{ vault_delete_marker: { key: string; body: unknown } | null }>(
        "SELECT public.vault_delete_marker($1::uuid)",
        [uploadId],
      );
      await client.query("SELECT public.delete_statement_upload($1::uuid)", [uploadId]);
      return found.rows[0]?.vault_delete_marker ?? null;
    });
    if (marker && process.env.CURATED_BUCKET) {
      try {
        await putVaultObject(marker.key, JSON.stringify(marker.body, null, 1), "application/json");
      } catch (error) {
        console.error("vault delete marker failed", error);
        return json(200, { ok: true, backup_warning: "The file was deleted. The vault delete marker could not be written." });
      }
    }
    return json(200, { ok: true });
  }

  return json(404, { error: "Not found" });
}

// sql/016: attribute lists (Lists page) and transfer links (Dimensions page).
async function dispatch016(
  claims: Record<string, string | undefined>,
  method: string,
  path: string,
  event: HttpEvent,
): Promise<HttpResult | null> {
  const call = async (sql: string, params: unknown[]): Promise<HttpResult> => {
    const value = await withSession(claims, async (client) => {
      const result = await client.query<{ value: unknown }>(`SELECT ${sql} AS value`, params);
      return result.rows[0]?.value;
    });
    return json(200, value ?? {});
  };
  const text = (value: unknown): string | null => (typeof value === "string" ? value : null);

  if (path === "/lists" && method === "GET") {
    return call("public.list_catalog()", []);
  }
  if (path === "/lists" && method === "POST") {
    return call("public.create_list($1)", [text(asObject(event.body).list_name)]);
  }
  const nestedList = path.match(/^\/lists\/([^/]+)\/nested$/);
  if (nestedList && method === "POST") {
    if (!ID_RE.test(nestedList[1])) {
      return json(400, { error: "list id is not valid" });
    }
    return call("public.create_nested_list($1::bigint, $2)", [nestedList[1], text(asObject(event.body).list_name)]);
  }
  const listItems = path.match(/^\/lists\/([^/]+)\/items$/);
  if (listItems && method === "POST") {
    if (!ID_RE.test(listItems[1])) {
      return json(400, { error: "list id is not valid" });
    }
    const body = asObject(event.body);
    const parent = body.parent_item_id === null || body.parent_item_id === undefined || body.parent_item_id === ""
      ? null
      : String(body.parent_item_id);
    if (parent !== null) {
      if (!ID_RE.test(parent)) {
        return json(400, { error: "item id is not valid" });
      }
      return call("public.add_list_item($1::bigint, $2, $3::bigint)", [listItems[1], text(body.item_name), parent]);
    }
    return call("public.add_list_item($1::bigint, $2)", [listItems[1], text(body.item_name)]);
  }
  const listRename = path.match(/^\/lists\/([^/]+)$/);
  if (listRename && method === "POST") {
    if (!ID_RE.test(listRename[1])) {
      return json(400, { error: "list id is not valid" });
    }
    return call("public.rename_list($1::bigint, $2)", [listRename[1], text(asObject(event.body).list_name)]);
  }
  const itemRename = path.match(/^\/list-items\/([^/]+)$/);
  if (itemRename && method === "POST") {
    if (!ID_RE.test(itemRename[1])) {
      return json(400, { error: "item id is not valid" });
    }
    return call("public.rename_list_item($1::bigint, $2)", [itemRename[1], text(asObject(event.body).item_name)]);
  }
  if (path === "/attribute-settings" && method === "POST") {
    const body = asObject(event.body);
    const listId = body.list_id === null || body.list_id === undefined || body.list_id === "" ? null : String(body.list_id);
    if (listId !== null && !ID_RE.test(listId)) {
      return json(400, { error: "list id is not valid" });
    }
    return call("public.set_attribute_setting($1::int, $2, $3::bigint)", [
      Number.parseInt(String(body.slot ?? ""), 10) || null,
      text(body.label),
      listId,
    ]);
  }

  if (path === "/transfers" && method === "GET") {
    return call("public.transfer_links()", []);
  }
  if (path === "/transfers" && method === "POST") {
    const body = asObject(event.body);
    return call("public.link_transfer($1, $2)", [text(body.row_a), text(body.row_b)]);
  }
  if (path === "/transfers/detect" && method === "POST") {
    const body = asObject(event.body);
    return call("public.detect_transfers($1::boolean)", [typeof body.create === "boolean" ? body.create : null]);
  }
  if (path === "/transfers/settings" && method === "POST") {
    const body = asObject(event.body);
    return call("public.set_transfer_auto($1::boolean)", [
      typeof body.auto_link_transfers === "boolean" ? body.auto_link_transfers : null,
    ]);
  }
  if (path === "/transfers/partners" && method === "GET") {
    const params = event.queryStringParameters ?? {};
    return call("public.transfer_partners($1, $2, $3::int)", [
      params.row_hash ?? null,
      typeof params.q === "string" ? params.q.slice(0, 100) : null,
      Number.parseInt(params.limit ?? "30", 10) || 30,
    ]);
  }
  const confirm = path.match(/^\/transfers\/([^/]+)\/confirm$/);
  if (confirm && method === "POST") {
    if (!HASH_RE.test(confirm[1])) {
      return json(400, { error: "link id is not valid" });
    }
    return call("public.confirm_transfer($1)", [confirm[1]]);
  }
  const unlink = path.match(/^\/transfers\/([^/]+)$/);
  if (unlink && method === "DELETE") {
    if (!HASH_RE.test(unlink[1])) {
      return json(400, { error: "link id is not valid" });
    }
    return call("public.unlink_transfer($1)", [unlink[1]]);
  }
  return null;
}

// sql/018: balances (opening balance, monthly reconciliation) for any account, banks
// (add, rename), moving an account to another bank, and the statement column map preview.
async function dispatch018(
  claims: Record<string, string | undefined>,
  method: string,
  path: string,
  event: HttpEvent,
): Promise<HttpResult | null> {
  if (!/^\/(balances|banks|accounts\/\d+(\/bank)?$|statements\/preview$)/.test(path)) {
    return null;
  }
  const call = async (sql: string, params: unknown[]): Promise<HttpResult> => {
    const value = await withSession(claims, async (client) => {
      const result = await client.query<{ value: unknown }>(`SELECT ${sql} AS value`, params);
      return result.rows[0]?.value;
    });
    return json(200, value ?? {});
  };
  const text = (value: unknown): string | null => (typeof value === "string" && value.trim() ? value : null);
  const int = (value: unknown): number | null => {
    const parsed = typeof value === "number" ? value : Number.parseInt(String(value ?? ""), 10);
    return Number.isInteger(parsed) ? parsed : null;
  };
  const amount = (value: unknown): string | null => {
    if (value === null || value === undefined || value === "") {
      return null;
    }
    const raw = String(value).replace(/,/g, "").trim();
    return /^-?\d+(\.\d+)?$/.test(raw) ? raw : "invalid";
  };
  const params = event.queryStringParameters ?? {};

  const balanceHome = path.match(/^\/balances\/(\d+)$/);
  if (method === "GET" && balanceHome) {
    return call("public.account_balance_home($1::int, $2::date)", [Number(balanceHome[1]), asDate(params.as_of ?? "")]);
  }
  if (method === "GET" && path === "/banks") {
    return call("public.bank_catalog()", []);
  }
  const balanceRow = path.match(/^\/balances\/rows\/([^/]+)$/);
  if (method === "POST" && balanceRow) {
    if (!HASH_RE.test(balanceRow[1])) {
      return json(400, { error: "id is not valid" });
    }
    const edit = asObject(event.body);
    const editedAmount = amount(edit.amount);
    if (editedAmount === null || editedAmount === "invalid") {
      return json(400, { error: "Type the amount" });
    }
    return call("public.update_balance_row($1, $2::date, $3::numeric)", [
      balanceRow[1],
      asDate(edit.txn_date),
      editedAmount,
    ]);
  }
  if (method === "DELETE" && balanceRow) {
    if (!HASH_RE.test(balanceRow[1])) {
      return json(400, { error: "id is not valid" });
    }
    return call("public.delete_balance_row($1)", [balanceRow[1]]);
  }
  const bankDelete = path.match(/^\/banks\/(\d+)$/);
  if (method === "DELETE" && bankDelete) {
    return call("public.delete_bank($1::int)", [Number(bankDelete[1])]);
  }
  const accountDelete = path.match(/^\/accounts\/(\d+)$/);
  if (method === "DELETE" && accountDelete) {
    return call("public.delete_bank_account($1::int)", [Number(accountDelete[1])]);
  }
  if (method !== "POST") {
    return null;
  }
  const body = asObject(event.body);
  if (path === "/balances/opening") {
    const balance = amount(body.balance);
    if (balance === null || balance === "invalid") {
      return json(400, { error: "Type the opening balance" });
    }
    return call("public.add_opening_balance($1::int, $2::numeric, $3::date, $4, $5)", [
      int(body.account_id),
      balance,
      asDate(body.txn_date),
      text(body.concept),
      text(body.note),
    ]);
  }
  if (path === "/balances/reconcile") {
    const reported = amount(body.reported_balance);
    if (reported === null || reported === "invalid") {
      return json(400, { error: "Type the balance the institution shows" });
    }
    return call("public.reconcile_account($1::int, $2::date, $3::numeric, $4::date, $5, $6)", [
      int(body.account_id),
      asDate(body.as_of),
      reported,
      asDate(body.adjust_date),
      text(body.concept),
      text(body.note),
    ]);
  }
  if (path === "/banks") {
    return call("public.create_bank($1, $2)", [text(body.bank_name), body.is_institution === true]);
  }
  const bank = path.match(/^\/banks\/(\d+)$/);
  if (bank) {
    return call("public.rename_bank($1::int, $2)", [Number(bank[1]), text(body.bank_name)]);
  }
  const accountBank = path.match(/^\/accounts\/(\d+)\/bank$/);
  if (accountBank) {
    return call("public.set_account_bank($1::int, $2::int)", [Number(accountBank[1]), int(body.bank_id)]);
  }
  if (path === "/statements/preview") {
    const csv = typeof body.csv === "string" ? body.csv : "";
    if (!csv || csv.length > 2_000_000) {
      return json(400, { error: "The file is empty or larger than 2 MB" });
    }
    const mapping =
      body.mapping && typeof body.mapping === "object" && !Array.isArray(body.mapping)
        ? JSON.stringify(body.mapping)
        : null;
    return call("public.column_map_preview($1::int, $2, $3::jsonb)", [int(body.account_id), csv, mapping]);
  }
  return null;
}

// sql/017: Investments & Assets page (master_closed_aaccandass_f).
async function dispatch017(
  claims: Record<string, string | undefined>,
  method: string,
  path: string,
  event: HttpEvent,
): Promise<HttpResult | null> {
  if (!path.startsWith("/assets")) {
    return null;
  }
  const call = async (sql: string, params: unknown[]): Promise<HttpResult> => {
    const value = await withSession(claims, async (client) => {
      const result = await client.query<{ value: unknown }>(`SELECT ${sql} AS value`, params);
      return result.rows[0]?.value;
    });
    return json(200, value ?? {});
  };
  const text = (value: unknown): string | null => (typeof value === "string" ? value : null);
  const int = (value: unknown): number | null => {
    const parsed = typeof value === "number" ? value : Number.parseInt(String(value ?? ""), 10);
    return Number.isInteger(parsed) ? parsed : null;
  };
  const amount = (value: unknown): string | null => {
    if (value === null || value === undefined || value === "") {
      return null;
    }
    const raw = String(value).replace(/,/g, "").trim();
    return /^-?\d+(\.\d+)?$/.test(raw) ? raw : "invalid";
  };
  const mapping = (value: unknown): string =>
    JSON.stringify(value && typeof value === "object" && !Array.isArray(value) ? value : {});
  const params = event.queryStringParameters ?? {};

  if (path === "/assets" && method === "GET") {
    return call("public.aaccandass_home($1::date)", [asDate(params.as_of ?? "")]);
  }
  if (path === "/assets/balances" && method === "GET") {
    return call("public.aaccandass_balances($1::date, $2::int)", [
      asDate(params.as_of ?? ""),
      int(params.months) ?? 12,
    ]);
  }
  if (path === "/assets/accounts" && method === "POST") {
    const body = asObject(event.body);
    return call("public.create_asset_account($1::int, $2, $3::int, $4, $5)", [
      int(body.bank_id),
      text(body.institution),
      int(body.a_type_id),
      text(body.account_name),
      text(body.account_number),
    ]);
  }
  if (path === "/assets/rows" && method === "GET") {
    return call("public.aaccandass_rows($1::int, $2::date, $3::date, $4, $5::int, $6::int)", [
      int(params.account_id),
      asDate(params.from ?? ""),
      asDate(params.to ?? ""),
      typeof params.q === "string" ? params.q.slice(0, 100) : null,
      int(params.limit) ?? 200,
      int(params.offset) ?? 0,
    ]);
  }
  if (path === "/assets/rows" && method === "POST") {
    const body = asObject(event.body);
    const abonos = amount(body.abonos);
    const cargos = amount(body.cargos);
    if (abonos === "invalid" || cargos === "invalid") {
      return json(400, { error: "Type amounts as numbers" });
    }
    return call("public.add_aaccandass_row($1::int, $2::date, $3, $4::numeric, $5::numeric, $6)", [
      int(body.account_id),
      asDate(body.txn_date),
      text(body.concept),
      abonos ?? "0",
      cargos ?? "0",
      text(body.note),
    ]);
  }
  const rowDelete = path.match(/^\/assets\/rows\/([^/]+)$/);
  if (rowDelete && method === "DELETE") {
    if (!HASH_RE.test(rowDelete[1])) {
      return json(400, { error: "row id is not valid" });
    }
    return call("public.delete_aaccandass_row($1)", [rowDelete[1]]);
  }
  if (path === "/assets/reconcile" && method === "POST") {
    const body = asObject(event.body);
    const reported = amount(body.reported_balance);
    if (reported === null || reported === "invalid") {
      return json(400, { error: "Type the balance the institution shows" });
    }
    return call("public.reconcile_aaccandass($1::int, $2::date, $3::numeric, $4::date, $5, $6)", [
      int(body.account_id),
      asDate(body.as_of),
      reported,
      asDate(body.adjust_date),
      text(body.concept),
      text(body.note),
    ]);
  }
  const templateDelete = path.match(/^\/assets\/templates\/([^/]+)$/);
  if (templateDelete && method === "DELETE") {
    if (!ID_RE.test(templateDelete[1])) {
      return json(400, { error: "template id is not valid" });
    }
    return call("public.delete_aaccandass_template($1::bigint)", [templateDelete[1]]);
  }
  if (path === "/assets/preview" && method === "POST") {
    const body = asObject(event.body);
    const csv = typeof body.csv === "string" ? body.csv : "";
    if (!csv || csv.length > 2_000_000) {
      return json(400, { error: "The file is empty or larger than 2 MB" });
    }
    return call("public.aaccandass_preview($1::int, $2, $3::jsonb)", [int(body.account_id), csv, mapping(body.mapping)]);
  }
  if (path === "/assets/uploads" && method === "POST") {
    const body = asObject(event.body);
    const csv = typeof body.csv === "string" ? body.csv : "";
    if (!csv || csv.length > 2_000_000) {
      return json(400, { error: "The file is empty or larger than 2 MB" });
    }
    const filename = text(body.filename) ?? "upload.csv";
    const ingested = await withSession(claims, async (client) => {
      const result = await client.query<{ value: UploadPayload }>(
        "SELECT public.ingest_aaccandass_upload($1::int, $2, $3, $4, $5::jsonb, $6, $7) AS value",
        [
          int(body.account_id),
          filename,
          text(body.chosen_filename) ?? filename,
          csv,
          mapping(body.mapping),
          text(body.template_name),
          body.source_format === "xlsx" ? "xlsx" : "csv",
        ],
      );
      return result.rows[0]?.value;
    });
    const payload = ingested ?? {};
    const { vault_metadata: vaultMetadata, vault_manifest: vaultManifest, vault_manifest_key: manifestKey, ...reply } =
      payload;
    if (payload.curated_csv_backup && payload.upload_id && payload.tenant_id && process.env.CURATED_BUCKET) {
      try {
        // Vault name from sql/017: curated/{tenant}/{YYYY-MM}_{account}_{Bank}_inv[_vN].csv.
        const key = payload.vault_key;
        if (!key || !key.startsWith(`curated/${payload.tenant_id}/`)) {
          throw new Error("vault key missing from ingest result");
        }
        const bodyBytes = Buffer.from(csv, "utf8");
        const objectSha256 = createHash("sha256").update(bodyBytes).digest("hex");
        await putVaultObject(key, bodyBytes, "text/csv; charset=utf-8", {
          ...(vaultMetadata ?? {}),
          "object-sha256": objectSha256,
        });
        await withSession(claims, async (client) => {
          await client.query("SELECT public.attach_aaccandass_backup($1::uuid, $2)", [payload.upload_id, key]);
        });
        let manifestWarning: string | undefined;
        if (manifestKey && vaultManifest) {
          try {
            const manifest = { ...vaultManifest, object_sha256: objectSha256, object_size: bodyBytes.length };
            await putVaultObject(manifestKey, JSON.stringify(manifest, null, 1), "application/json");
          } catch (error) {
            console.error("vault manifest failed", error);
            manifestWarning = "The file was saved in the vault, but its manifest could not be written.";
          }
        }
        return json(200, { ...reply, curated_s3_key: key, ...(manifestWarning ? { backup_warning: manifestWarning } : {}) });
      } catch (error) {
        console.error("curated backup failed", error);
        return json(200, { ...reply, backup_warning: "The rows were saved. The curated backup could not be written." });
      }
    }
    return json(200, reply);
  }
  const uploadDelete = path.match(/^\/assets\/uploads\/([^/]+)$/);
  if (uploadDelete && method === "DELETE") {
    if (!UUID_RE.test(uploadDelete[1])) {
      return json(400, { error: "upload id is not valid" });
    }
    const deleted = await withSession(claims, async (client) => {
      const result = await client.query<{ value: { vault_delete_marker?: { key: string; body: unknown } | null } }>(
        "SELECT public.delete_aaccandass_upload($1::uuid) AS value",
        [uploadDelete[1]],
      );
      return result.rows[0]?.value ?? {};
    });
    const { vault_delete_marker: marker, ...reply } = deleted;
    if (marker && process.env.CURATED_BUCKET) {
      try {
        await putVaultObject(marker.key, JSON.stringify(marker.body, null, 1), "application/json");
      } catch (error) {
        console.error("vault delete marker failed", error);
        return json(200, { ...reply, backup_warning: "The file was deleted. The vault delete marker could not be written." });
      }
    }
    return json(200, reply);
  }
  return json(404, { error: "Not found" });
}
