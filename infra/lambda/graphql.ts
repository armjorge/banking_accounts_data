// POST /graphql for Google Sheets (sql/015, docs/graphql.md). Auth is a read-only API
// token (not Cognito). Order: size and query checks -> quota (one call per request) ->
// read-only strm_app session -> resolve -> log. Small bundle: pg + graphql + SSM only.
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import pg from "pg";
import {
  ApiError,
  MAX_BODY_BYTES,
  MAX_RESPONSE_BYTES,
  type Usage,
  bearerToken,
  overQuotaBody,
  prepare,
  retryAfterSeconds,
  run,
  usagePublic,
} from "./graphql-core.js";

const ssm = new SSMClient({});
let cachedUrl: string | undefined;

interface HttpEvent {
  body?: string | null;
  isBase64Encoded?: boolean;
  headers?: Record<string, string | undefined>;
  requestContext?: { http?: { method?: string } };
}

interface HttpResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

function json(statusCode: number, body: unknown, headers: Record<string, string> = {}): HttpResult {
  return {
    statusCode,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
    body: JSON.stringify(body),
  };
}

async function neonUrl(): Promise<string> {
  if (cachedUrl) {
    return cachedUrl;
  }
  const name = process.env.NEON_URL_PARAM;
  if (!name) {
    throw new Error("NEON_URL_PARAM is not set");
  }
  const result = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  const value = result.Parameter?.Value;
  if (!value) {
    throw new Error("Neon URL parameter is empty");
  }
  const parsed = new URL(value);
  parsed.searchParams.delete("channel_binding");
  if (!parsed.searchParams.get("sslmode")) {
    parsed.searchParams.set("sslmode", "require");
  }
  cachedUrl = parsed.toString();
  return cachedUrl;
}

function header(event: HttpEvent, name: string): string | undefined {
  const headers = event.headers ?? {};
  return headers[name] ?? headers[name.toLowerCase()];
}

export async function handler(event: HttpEvent): Promise<HttpResult> {
  if ((event.requestContext?.http?.method ?? "POST") !== "POST") {
    return json(405, { error: "Use POST" });
  }
  const body = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString("utf8") : (event.body ?? "");
  if (Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
    return json(413, { error: `The request is larger than ${MAX_BODY_BYTES} bytes` });
  }
  let token: string;
  let prepared: ReturnType<typeof prepare>;
  try {
    token = bearerToken(header(event, "authorization"));
    prepared = prepare(body);
  } catch (error) {
    if (error instanceof ApiError) {
      return json(error.status, { error: error.message });
    }
    throw error;
  }

  const client = new pg.Client({
    connectionString: await neonUrl(),
    ssl: { rejectUnauthorized: true },
    statement_timeout: 10_000,
  });
  await client.connect();
  try {
    let usage: Usage;
    try {
      const consumed = await client.query<{ api_consume_call: Usage }>(
        "SELECT public.api_consume_call($1, 'graphql')",
        [token],
      );
      usage = consumed.rows[0]?.api_consume_call ?? {};
    } catch (error) {
      if (typeof error === "object" && error !== null && "code" in error && error.code === "28000") {
        return json(401, { error: "invalid or revoked API token" });
      }
      throw error;
    }
    if (!usage.ok || !usage.call_id) {
      const retry = retryAfterSeconds(usage);
      return json(429, overQuotaBody(usage), retry ? { "retry-after": String(retry) } : {});
    }

    let status = "error";
    let rowCount = 0;
    try {
      await client.query("BEGIN READ ONLY");
      await client.query("SELECT set_config('app.user_id', $1, true)", [usage.user_id]);
      await client.query("SELECT set_config('app.tenant_id', $1, true)", [usage.tenant_id]);
      await client.query("SET LOCAL ROLE strm_app");
      const result = await run(
        prepared,
        async (table, months, upcomingOnly, limit, excludeTransfers) => {
          const rows = await client.query<{ graphql_rows: Record<string, unknown>[] }>(
            `SELECT public.graphql_rows(
               $1, $2::int,
               CASE WHEN $3::boolean THEN (NOW() AT TIME ZONE 'America/Mexico_City')::date END,
               NULL, $4::int, $5::boolean
             )`,
            [table, months, upcomingOnly, limit, excludeTransfers],
          );
          return rows.rows[0]?.graphql_rows ?? [];
        },
        usage,
      );
      await client.query("COMMIT");
      rowCount = result.rowCount;
      const payload = {
        ...result.body,
        extensions: { usage: usagePublic(usage), rows: result.rowCount, truncated: result.truncated },
      };
      const encoded = JSON.stringify(payload);
      if (Buffer.byteLength(encoded, "utf8") > MAX_RESPONSE_BYTES) {
        return json(413, {
          error: "The response is too large; ask for fewer months, rows or columns",
          usage: usagePublic(usage),
        });
      }
      status = result.body.errors?.length ? "error" : "ok";
      return { statusCode: 200, headers: { "content-type": "application/json", "cache-control": "no-store" }, body: encoded };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => undefined);
      console.error("graphql request failed", error);
      return json(500, { error: "The query could not be answered.", usage: usagePublic(usage) });
    } finally {
      await client
        .query("SELECT public.api_finish_call($1, $2, $3)", [usage.call_id, status, rowCount])
        .catch((error: unknown) => console.error("api_finish_call failed", error));
    }
  } finally {
    await client.end();
  }
}
