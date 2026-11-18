// Read-only GraphQL API over the five master tables (sql/015, docs/graphql.md).
// Pure logic shared by the Lambda (graphql.ts) and the node test; no AWS or pg imports.
// Python twin: apps/statements/graphql_api.py. The SDL and limits must stay identical.
import {
  type DocumentNode,
  type FragmentDefinitionNode,
  GraphQLError,
  Kind,
  type OperationDefinitionNode,
  type SelectionSetNode,
  buildSchema,
  execute,
  parse,
  specifiedRules,
  validate,
} from "graphql";

// --- shared with graphql_api.py (keep identical) ---
export const SDL = `
enum Kind {
  DEBIT
  CREDIT
  ASSET
}

enum Layer {
  CLOSED
  OPEN
  FUTURE
}

type Movement {
  row_hash: String!
  table: String!
  layer: String!
  kind: String!
  row_id: Int!
  account_id: Int!
  account_number: String
  bank_id: Int
  bank_name: String
  period_start: String
  period_end: String
  txn_date: String!
  concept: String
  concept_sk: String
  abonos: Float
  cargos: Float
  amount: Float
  occurrence: Int
  file_name: String
  source_profile: String
  balance: Float
  entry_source: String
  cutoff_id: Int
  attribute_1: String
  attribute_2: String
  attribute_3: String
  is_internal_transfer: Boolean!
  transfer_link_hash: String
  transfer_role: String
  transfer_type: String
  transfer_source: String
  transfer_counterpart_account: String
}

type Usage {
  plan_code: String!
  used: Int!
  limit: Int!
  remaining: Int!
  window: String!
  resets_at: String!
  max_rows: Int!
}

type Query {
  movements(kind: Kind!, layer: Layer!, months: Int, upcomingOnly: Boolean, excludeTransfers: Boolean, limit: Int): [Movement!]
  usage: Usage!
}
`;

export const MAX_BODY_BYTES = 16384;
export const MAX_QUERY_CHARS = 8000;
export const MAX_DEPTH = 3;
export const MAX_ROOT_FIELDS = 8;
export const MAX_FIELDS = 250;
export const MAX_RESPONSE_BYTES = 5_500_000;
export const DEFAULT_CLOSED_MONTHS = 12;
export const TOKEN_RE = /^bst_[0-9a-f]{48}$/;
// ---

const TABLES: Record<string, string> = {
  "DEBIT:CLOSED": "master_debit_closed_f",
  "DEBIT:OPEN": "master_debit_open_f",
  "CREDIT:CLOSED": "master_credit_closed_f",
  "CREDIT:OPEN": "master_credit_open_f",
  "CREDIT:FUTURE": "master_credit_future_f",
  "ASSET:CLOSED": "master_closed_aaccandass_f",
  "ASSET:OPEN": "master_open_aaccandass_f",
};

export const schema = buildSchema(SDL);

export class ApiError extends Error {
  public constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface Prepared {
  document: DocumentNode;
  variables: Record<string, unknown>;
  operationName: string | null;
  rootFields: number;
}

export interface Usage {
  ok?: boolean;
  call_id?: number;
  tenant_id?: string;
  user_id?: string;
  plan_code?: string;
  plan_name?: string;
  used?: number;
  limit?: number;
  remaining?: number;
  window?: string;
  resets_at?: string;
  max_rows?: number;
}

/** Runs graphql_rows(table, months, upcomingOnly, limit, excludeTransfers) in the caller's strm_app session. */
export type RowsQuery = (
  table: string,
  months: number | null,
  upcomingOnly: boolean,
  limit: number,
  excludeTransfers: boolean,
) => Promise<Record<string, unknown>[]>;

interface Context {
  rows: RowsQuery;
  usage: Usage;
  rowsLeft: number;
  rowCount: number;
  truncated: string[];
  // graphql-js starts root fields together; the shared row budget needs them one by one
  // (in document order, like the Python twin).
  queue: Promise<void>;
}

export function bearerToken(header: string | undefined | null): string {
  const value = (header ?? "").trim();
  if (!value.toLowerCase().startsWith("bearer ")) {
    throw new ApiError(401, "Send the API token as: Authorization: Bearer <token>");
  }
  const token = value.slice(7).trim();
  if (!TOKEN_RE.test(token)) {
    throw new ApiError(401, "invalid or revoked API token");
  }
  return token;
}

function depthAndCount(
  selectionSet: SelectionSetNode | undefined,
  fragments: Map<string, FragmentDefinitionNode>,
  depth: number,
  seen: Set<string>,
): [number, number] {
  if (!selectionSet) {
    return [depth - 1, 0];
  }
  let deepest = depth;
  let count = 0;
  for (const node of selectionSet.selections) {
    if (node.kind === Kind.FIELD) {
      if (node.name.value === "__schema" || node.name.value === "__type") {
        throw new ApiError(400, "Introspection is turned off; see docs/graphql.md for the schema");
      }
      count += 1;
      const [innerDepth, innerCount] = depthAndCount(node.selectionSet, fragments, depth + 1, seen);
      deepest = Math.max(deepest, innerDepth);
      count += innerCount;
    } else if (node.kind === Kind.INLINE_FRAGMENT) {
      const [innerDepth, innerCount] = depthAndCount(node.selectionSet, fragments, depth, seen);
      deepest = Math.max(deepest, innerDepth);
      count += innerCount;
    } else if (node.kind === Kind.FRAGMENT_SPREAD) {
      const name = node.name.value;
      const fragment = fragments.get(name);
      if (seen.has(name) || !fragment) {
        continue;
      }
      const [innerDepth, innerCount] = depthAndCount(
        fragment.selectionSet,
        fragments,
        depth,
        new Set([...seen, name]),
      );
      deepest = Math.max(deepest, innerDepth);
      count += innerCount;
    }
  }
  return [deepest, count];
}

function rootFieldCount(
  selectionSet: SelectionSetNode,
  fragments: Map<string, FragmentDefinitionNode>,
  seen: Set<string>,
): number {
  let total = 0;
  for (const node of selectionSet.selections) {
    if (node.kind === Kind.FIELD) {
      total += node.name.value === "__typename" ? 0 : 1;
    } else if (node.kind === Kind.INLINE_FRAGMENT) {
      total += rootFieldCount(node.selectionSet, fragments, seen);
    } else if (node.kind === Kind.FRAGMENT_SPREAD) {
      const fragment = fragments.get(node.name.value);
      if (fragment && !seen.has(node.name.value)) {
        total += rootFieldCount(fragment.selectionSet, fragments, new Set([...seen, node.name.value]));
      }
    }
  }
  return total;
}

/** Checks the request before any quota is spent. Throws ApiError(400/413). */
export function prepare(body: string | null | undefined): Prepared {
  const raw = body ?? "";
  if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) {
    throw new ApiError(413, `The request is larger than ${MAX_BODY_BYTES} bytes`);
  }
  let payload: unknown;
  try {
    payload = JSON.parse(raw || "{}");
  } catch {
    throw new ApiError(400, "The request body is not valid JSON");
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new ApiError(400, 'Send {"query": "...", "variables": {...}}');
  }
  const request = payload as Record<string, unknown>;
  if (typeof request.query !== "string") {
    throw new ApiError(400, 'Send {"query": "...", "variables": {...}}');
  }
  const query = request.query;
  if (query.length > MAX_QUERY_CHARS) {
    throw new ApiError(413, `The query is longer than ${MAX_QUERY_CHARS} characters`);
  }
  const variables = request.variables ?? {};
  if (typeof variables !== "object" || variables === null || Array.isArray(variables)) {
    throw new ApiError(400, "variables must be an object");
  }
  const operationName = request.operationName ?? null;
  if (operationName !== null && typeof operationName !== "string") {
    throw new ApiError(400, "operationName must be a string");
  }
  let document: DocumentNode;
  try {
    document = parse(query, { maxTokens: 2000 });
  } catch (error) {
    const message = error instanceof GraphQLError ? error.message : String(error);
    throw new ApiError(400, `GraphQL syntax error: ${message}`);
  }
  const errors = validate(schema, document, specifiedRules);
  if (errors.length > 0) {
    throw new ApiError(400, errors.slice(0, 5).map((error) => error.message).join("; "));
  }
  let operations = document.definitions.filter(
    (item): item is OperationDefinitionNode => item.kind === Kind.OPERATION_DEFINITION,
  );
  const fragments = new Map<string, FragmentDefinitionNode>();
  for (const item of document.definitions) {
    if (item.kind === Kind.FRAGMENT_DEFINITION) {
      fragments.set(item.name.value, item);
    }
  }
  if (operationName) {
    operations = operations.filter((item) => item.name?.value === operationName);
  }
  if (operations.length !== 1) {
    throw new ApiError(400, "Send exactly one query operation per request");
  }
  const operation = operations[0];
  if (operation.operation !== "query") {
    throw new ApiError(400, "Only queries are allowed; the API is read-only");
  }
  const [depth, count] = depthAndCount(operation.selectionSet, fragments, 1, new Set());
  if (depth > MAX_DEPTH) {
    throw new ApiError(400, `The query is nested deeper than ${MAX_DEPTH} levels`);
  }
  if (count > MAX_FIELDS) {
    throw new ApiError(400, `The query selects more than ${MAX_FIELDS} fields`);
  }
  const roots = rootFieldCount(operation.selectionSet, fragments, new Set());
  if (roots > MAX_ROOT_FIELDS) {
    throw new ApiError(400, `At most ${MAX_ROOT_FIELDS} root fields (tabs) per request`);
  }
  return { document, variables: variables as Record<string, unknown>, operationName, rootFields: roots };
}

interface MovementArgs {
  kind: string;
  layer: string;
  months?: number | null;
  upcomingOnly?: boolean | null;
  excludeTransfers?: boolean | null;
  limit?: number | null;
}

async function movementRows(
  args: MovementArgs,
  context: Context,
  alias: string,
): Promise<Record<string, unknown>[]> {
  const table = TABLES[`${args.kind}:${args.layer}`];
  if (!table) {
    throw new GraphQLError(`${alias}: there is no ${args.kind.toLowerCase()} ${args.layer.toLowerCase()} table`);
  }
  let months = args.months ?? null;
  if (months === null && args.layer === "CLOSED") {
    months = DEFAULT_CLOSED_MONTHS;
  }
  if (months !== null && (months < 1 || months > 120)) {
    throw new GraphQLError(`${alias}: months must be between 1 and 120`);
  }
  const requested = args.limit ?? null;
  if (requested !== null && requested < 1) {
    throw new GraphQLError(`${alias}: limit must be at least 1`);
  }
  const budget = requested === null ? context.rowsLeft : Math.min(requested, context.rowsLeft);
  if (budget <= 0) {
    context.truncated.push(alias);
    return [];
  }
  const upcoming = Boolean(args.upcomingOnly) && args.layer === "FUTURE";
  const exclude = Boolean(args.excludeTransfers);
  let rows = await context.rows(table, months, upcoming, budget + 1, exclude);
  if (rows.length > budget) {
    context.truncated.push(alias);
    rows = rows.slice(rows.length - budget);
  }
  context.rowsLeft -= rows.length;
  context.rowCount += rows.length;
  // sql/016 fields; a row without them (016 not applied yet) is not a transfer.
  return rows.map((row) => ({ is_internal_transfer: false, ...row }));
}

const root = {
  async movements(
    args: MovementArgs,
    context: Context,
    info: { path: { key: string | number } },
  ): Promise<Record<string, unknown>[]> {
    const previous = context.queue;
    let release: () => void = () => undefined;
    context.queue = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await movementRows(args, context, String(info.path.key));
    } finally {
      release();
    }
  },
  usage(_args: unknown, context: Context): Record<string, unknown> {
    const usage = context.usage;
    return {
      plan_code: usage.plan_code ?? "",
      used: usage.used ?? 0,
      limit: usage.limit ?? 0,
      remaining: usage.remaining ?? 0,
      window: usage.window ?? "week",
      resets_at: String(usage.resets_at ?? ""),
      max_rows: usage.max_rows ?? 0,
    };
  },
};

export interface RunResult {
  body: { data?: unknown; errors?: { message: string; path?: readonly (string | number)[] }[] };
  rowCount: number;
  truncated: string[];
}

/** Executes a prepared query; rows() must run inside the strm_app session. */
export async function run(prepared: Prepared, rows: RowsQuery, usage: Usage): Promise<RunResult> {
  const context: Context = {
    rows,
    usage,
    rowsLeft: Number(usage.max_rows ?? 5000),
    rowCount: 0,
    truncated: [],
    queue: Promise.resolve(),
  };
  const result = await execute({
    schema,
    document: prepared.document,
    rootValue: root,
    contextValue: context,
    variableValues: prepared.variables,
    operationName: prepared.operationName,
  });
  const body: RunResult["body"] = { data: result.data };
  if (result.errors?.length) {
    body.errors = result.errors.map((error) => ({ message: error.message, path: error.path }));
  }
  return { body, rowCount: context.rowCount, truncated: context.truncated };
}

export function usagePublic(usage: Usage): Record<string, unknown> {
  return {
    plan_code: usage.plan_code ?? null,
    used: usage.used ?? null,
    limit: usage.limit ?? null,
    remaining: usage.remaining ?? null,
    window: usage.window ?? null,
    resets_at: usage.resets_at ?? null,
    max_rows: usage.max_rows ?? null,
  };
}

export function overQuotaBody(usage: Usage): Record<string, unknown> {
  const window = usage.window === "day" ? "day" : "week";
  const limit = usage.limit ?? 0;
  const plan = usage.plan_name ? `${usage.plan_name} ` : "";
  const message =
    limit === 0
      ? `Your ${usage.plan_name || "current"} plan does not include API calls.`
      : `API limit reached: your ${plan}plan allows ${limit} ${limit === 1 ? "call" : "calls"} per ${window}. ` +
        `It resets at ${usage.resets_at}.`;
  return {
    error: message,
    code: "QUOTA_EXCEEDED",
    limit,
    used: usage.used,
    window,
    resets_at: usage.resets_at,
  };
}

export function retryAfterSeconds(usage: Usage, now: Date = new Date()): number | null {
  if (!usage.resets_at) {
    return null;
  }
  const reset = Date.parse(usage.resets_at);
  if (Number.isNaN(reset)) {
    return null;
  }
  return Math.max(Math.floor((reset - now.getTime()) / 1000), 1);
}
