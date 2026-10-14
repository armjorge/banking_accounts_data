import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import pg from "pg";

const SCHEMA_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const ssm = new SSMClient({});

interface CognitoTriggerEvent {
  request?: {
    userAttributes?: Record<string, string>;
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

async function parameter(name: string, decrypt = false): Promise<string> {
  const result = await ssm.send(
    new GetParameterCommand({ Name: name, WithDecryption: decrypt }),
  );
  const value = result.Parameter?.Value;
  if (!value) {
    throw new Error(`SSM parameter ${name} is empty`);
  }
  return value;
}

export async function handler(event: CognitoTriggerEvent): Promise<CognitoTriggerEvent> {
  try {
    const sub = event.request?.userAttributes?.sub;
    const email = event.request?.userAttributes?.email;
    if (!sub || !email) {
      return event;
    }
    const urlName = process.env.NEON_URL_PARAM;
    const schemaName = process.env.USERS_SCHEMA_PARAM;
    if (!urlName || !schemaName) {
      return event;
    }
    const url = connectableUrl(await parameter(urlName, true));
    const schema = await parameter(schemaName);
    if (!SCHEMA_RE.test(schema)) {
      return event;
    }
    const client = new pg.Client({
      connectionString: url,
      ssl: { rejectUnauthorized: true },
    });
    await client.connect();
    try {
      await client.query(
        `INSERT INTO ${schema}.users (cognito_sub, email)
         VALUES ($1, $2)
         ON CONFLICT (cognito_sub) DO UPDATE SET email = EXCLUDED.email`,
        [sub, email],
      );
    } finally {
      await client.end();
    }
  } catch (error) {
    console.error("upsert cognito user failed", error);
  }
  return event;
}
