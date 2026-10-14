import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import pg from "pg";

const ssm = new SSMClient({});

interface HttpEvent {
  rawPath?: string;
  body?: string | null;
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

function json(statusCode: number, body: unknown): HttpResult {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

function isAdmin(claims: Record<string, string | undefined>): boolean {
  const raw = claims["cognito:groups"] ?? "";
  return String(raw)
    .split(/[^A-Za-z0-9_-]+/)
    .includes("admin");
}

function asId(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    return null;
  }
  return parsed;
}

function asText(value: unknown, max = 500): string | null {
  if (value == null) {
    return null;
  }
  const text = String(value).trim();
  if (!text) {
    return null;
  }
  return text.slice(0, max);
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

async function withClient<T>(run: (client: pg.Client) => Promise<T>): Promise<T> {
  const client = new pg.Client({
    connectionString: await neonUrl(),
    ssl: { rejectUnauthorized: true },
  });
  await client.connect();
  try {
    return await run(client);
  } finally {
    await client.end();
  }
}

function isForeignKey(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23503";
}

export async function handler(event: HttpEvent): Promise<HttpResult> {
  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  if (!isAdmin(claims)) {
    return json(403, { error: "Admin group required" });
  }
  const method = event.requestContext?.http?.method ?? "GET";
  const path = (event.rawPath ?? "").replace(/\/+$/, "") || "/";
  try {
    return await withClient((client) => route(client, method, path, event.body));
  } catch (error) {
    if (isForeignKey(error)) {
      return json(409, { error: "That row is still used by a template or a bank account." });
    }
    console.error("admin dimensions failed", error);
    return json(500, { error: "Could not update the banking tables." });
  }
}

async function route(
  client: pg.Client,
  method: string,
  path: string,
  rawBody: string | null | undefined,
): Promise<HttpResult> {
  if (method === "GET" && path === "/admin") {
    const banks = await client.query(
      "SELECT bank_id, bank_name FROM public.banks_d ORDER BY bank_id",
    );
    const accountTypes = await client.query(
      "SELECT a_type_id, type_name FROM public.account_types_d ORDER BY a_type_id",
    );
    const templates = await client.query(
      `SELECT t.bank_id, b.bank_name, t.a_type_id, a.type_name, t.headers
       FROM public.bank_templates_f AS t
       JOIN public.banks_d AS b ON b.bank_id = t.bank_id
       JOIN public.account_types_d AS a ON a.a_type_id = t.a_type_id
       ORDER BY t.bank_id, t.a_type_id`,
    );
    return json(200, {
      banks: banks.rows,
      accountTypes: accountTypes.rows,
      templates: templates.rows,
    });
  }

  const body = parseBody(rawBody);
  if (method === "PUT" && path === "/admin/banks") {
    const bankId = asId(body.bank_id);
    if (!bankId) {
      return json(400, { error: "bank_id is required" });
    }
    await client.query(
      `INSERT INTO public.banks_d (bank_id, bank_name)
       VALUES ($1, $2)
       ON CONFLICT (bank_id) DO UPDATE SET bank_name = EXCLUDED.bank_name`,
      [bankId, asText(body.bank_name, 200)],
    );
    return json(200, { ok: true });
  }

  const bankDelete = path.match(/^\/admin\/banks\/(\d+)$/);
  if (method === "DELETE" && bankDelete) {
    await client.query("DELETE FROM public.banks_d WHERE bank_id = $1", [Number(bankDelete[1])]);
    return json(200, { ok: true });
  }

  if (method === "PUT" && path === "/admin/account-types") {
    const typeId = asId(body.a_type_id);
    const typeName = asText(body.type_name, 80);
    if (!typeId || !typeName) {
      return json(400, { error: "a_type_id and type_name are required" });
    }
    await client.query(
      `INSERT INTO public.account_types_d (a_type_id, type_name)
       VALUES ($1, $2)
       ON CONFLICT (a_type_id) DO UPDATE SET type_name = EXCLUDED.type_name`,
      [typeId, typeName],
    );
    return json(200, { ok: true });
  }

  const typeDelete = path.match(/^\/admin\/account-types\/(\d+)$/);
  if (method === "DELETE" && typeDelete) {
    await client.query("DELETE FROM public.account_types_d WHERE a_type_id = $1", [
      Number(typeDelete[1]),
    ]);
    return json(200, { ok: true });
  }

  if (method === "PUT" && path === "/admin/templates") {
    const bankId = asId(body.bank_id);
    const typeId = asId(body.a_type_id);
    if (!bankId || !typeId) {
      return json(400, { error: "bank_id and a_type_id are required" });
    }
    await client.query(
      `INSERT INTO public.bank_templates_f (bank_id, a_type_id, headers)
       VALUES ($1, $2, $3)
       ON CONFLICT (bank_id, a_type_id) DO UPDATE SET headers = EXCLUDED.headers`,
      [bankId, typeId, asText(body.headers, 2000)],
    );
    return json(200, { ok: true });
  }

  const templateDelete = path.match(/^\/admin\/templates\/(\d+)\/(\d+)$/);
  if (method === "DELETE" && templateDelete) {
    await client.query(
      "DELETE FROM public.bank_templates_f WHERE bank_id = $1 AND a_type_id = $2",
      [Number(templateDelete[1]), Number(templateDelete[2])],
    );
    return json(200, { ok: true });
  }

  return json(404, { error: "Not found" });
}

function parseBody(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) {
    return {};
  }
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {};
  }
  return parsed as Record<string, unknown>;
}
