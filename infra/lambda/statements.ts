import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import pg from "pg";

const ssm = new SSMClient({});
const s3 = new S3Client({});
const RETENTION_DAYS = 365;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

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
      return result.rows[0]?.statement_home;
    });
    return json(200, home ?? {});
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
    const asOf = asDate(body.as_of);
    const pdfBase64 = typeof body.pdf_base64 === "string" ? body.pdf_base64 : "";
    const csv = typeof body.csv === "string" ? body.csv : "";
    if (slot === "pdf") {
      if (!pdfBase64 || pdfBase64.length > 3_000_000) {
        return json(400, { error: "The PDF is empty or larger than 2 MB" });
      }
    } else if (!csv || csv.length > 2_000_000) {
      return json(400, { error: "The CSV is empty or larger than 2 MB" });
    }
    const ingested = await withSession(claims, async (client) => {
      const result =
        slot === "pdf"
          ? await client.query(
              `SELECT public.ingest_period_pdf($1, $2, $3, $4, COALESCE($5::date, CURRENT_DATE))`,
              [body.account_id, body.cutoff_id, filename, pdfBase64, asOf],
            )
          : await client.query(
              `SELECT public.ingest_statement_csv($1, $2, $3, $4, $5, COALESCE($6::date, CURRENT_DATE))`,
              [body.account_id, body.cutoff_id, slot, filename, csv, asOf],
            );
      const row = result.rows[0] as { ingest_statement_csv?: UploadPayload; ingest_period_pdf?: UploadPayload } | undefined;
      return row?.ingest_statement_csv ?? row?.ingest_period_pdf;
    });
    const payload = ingested ?? {};
    if (payload.curated_csv_backup && payload.upload_id && payload.tenant_id && process.env.CURATED_BUCKET) {
      try {
        const suffix = payload.file_suffix === "pdf" ? "pdf" : "csv";
        const key = `curated/${payload.tenant_id}/${payload.upload_id}.${suffix}`;
        const retainUntil = new Date(Date.now() + RETENTION_DAYS * 24 * 60 * 60 * 1000);
        const bodyBytes = suffix === "pdf" ? Buffer.from(pdfBase64, "base64") : csv;
        await s3.send(
          new PutObjectCommand({
            Bucket: process.env.CURATED_BUCKET,
            Key: key,
            Body: bodyBytes,
            ContentType: suffix === "pdf" ? "application/pdf" : "text/csv; charset=utf-8",
            IfNoneMatch: "*",
            ObjectLockMode: "GOVERNANCE",
            ObjectLockRetainUntilDate: retainUntil,
          }),
        );
        await withSession(claims, async (client) => {
          await client.query("SELECT public.attach_curated_backup($1::uuid, $2)", [
            payload.upload_id,
            key,
          ]);
        });
        return json(200, { ...payload, curated_s3_key: key });
      } catch (error) {
        console.error("curated backup failed", error);
        return json(200, {
          ...payload,
          backup_warning: "The working file was saved. The curated backup could not be written.",
        });
      }
    }
    return json(200, payload);
  }

  const uploadDelete = path.match(/^\/uploads\/([^/]+)$/);
  if (method === "DELETE" && uploadDelete) {
    const uploadId = uploadDelete[1];
    if (!UUID_RE.test(uploadId)) {
      return json(400, { error: "upload id is not valid" });
    }
    await withSession(claims, async (client) => {
      await client.query("SELECT public.delete_statement_upload($1::uuid)", [uploadId]);
    });
    return json(200, { ok: true });
  }

  return json(404, { error: "Not found" });
}
