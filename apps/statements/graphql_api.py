"""Read-only GraphQL API over the five master tables (sql/015, docs/graphql.md).

Python twin of infra/lambda/graphql-core.ts, used by local_api.py and the tests. The SDL
and the limits below must match the TypeScript file (a test compares them).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from typing import Any

import psycopg
from graphql import (
    DocumentNode,
    FieldNode,
    FragmentDefinitionNode,
    FragmentSpreadNode,
    GraphQLError,
    InlineFragmentNode,
    OperationDefinitionNode,
    OperationType,
    SelectionSetNode,
    build_schema,
    execute,
    parse,
    specified_rules,
    validate,
)

# --- shared with graphql-core.ts (keep identical) -------------------------------------
SDL = """
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
  attribute_4: String
  attribute_5: String
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
"""

MAX_BODY_BYTES = 16384
MAX_QUERY_CHARS = 8000
MAX_DEPTH = 3
MAX_ROOT_FIELDS = 8
MAX_FIELDS = 250
MAX_RESPONSE_BYTES = 5_500_000
DEFAULT_CLOSED_MONTHS = 12
TOKEN_RE = re.compile(r"^bst_[0-9a-f]{48}$")
# ---------------------------------------------------------------------------------------

TABLES = {
    ("DEBIT", "CLOSED"): "master_debit_closed_f",
    ("DEBIT", "OPEN"): "master_debit_open_f",
    ("CREDIT", "CLOSED"): "master_credit_closed_f",
    ("CREDIT", "OPEN"): "master_credit_open_f",
    ("CREDIT", "FUTURE"): "master_credit_future_f",
    ("ASSET", "CLOSED"): "master_closed_aaccandass_f",
    ("ASSET", "OPEN"): "master_open_aaccandass_f",
}

SCHEMA = build_schema(SDL)


class ApiError(Exception):
    def __init__(self, status: int, message: str, extra: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.extra = extra or {}


@dataclass
class Prepared:
    document: DocumentNode
    variables: dict[str, Any]
    operation_name: str | None
    root_fields: int


@dataclass
class Context:
    cur: psycopg.Cursor[Any]
    usage: dict[str, Any]
    rows_left: int
    rows: int = 0
    truncated: list[str] = field(default_factory=list)


def bearer_token(header: str | None) -> str:
    value = (header or "").strip()
    if not value.lower().startswith("bearer "):
        raise ApiError(401, "Send the API token as: Authorization: Bearer <token>")
    token = value[7:].strip()
    if not TOKEN_RE.fullmatch(token):
        raise ApiError(401, "invalid or revoked API token")
    return token


def _depth_and_count(
    selection_set: SelectionSetNode | None,
    fragments: dict[str, FragmentDefinitionNode],
    depth: int,
    seen: frozenset[str],
) -> tuple[int, int]:
    if selection_set is None:
        return depth - 1, 0
    deepest = depth
    count = 0
    for node in selection_set.selections:
        if isinstance(node, FieldNode):
            if node.name.value in {"__schema", "__type"}:
                raise ApiError(400, "Introspection is turned off; see docs/graphql.md for the schema")
            count += 1
            inner_depth, inner_count = _depth_and_count(node.selection_set, fragments, depth + 1, seen)
            deepest = max(deepest, inner_depth)
            count += inner_count
        elif isinstance(node, InlineFragmentNode):
            inner_depth, inner_count = _depth_and_count(node.selection_set, fragments, depth, seen)
            deepest = max(deepest, inner_depth)
            count += inner_count
        elif isinstance(node, FragmentSpreadNode):
            name = node.name.value
            if name in seen or name not in fragments:
                continue
            inner_depth, inner_count = _depth_and_count(
                fragments[name].selection_set, fragments, depth, seen | {name}
            )
            deepest = max(deepest, inner_depth)
            count += inner_count
    return deepest, count


def _root_field_count(
    selection_set: SelectionSetNode, fragments: dict[str, FragmentDefinitionNode], seen: frozenset[str]
) -> int:
    total = 0
    for node in selection_set.selections:
        if isinstance(node, FieldNode):
            total += 0 if node.name.value == "__typename" else 1
        elif isinstance(node, InlineFragmentNode):
            total += _root_field_count(node.selection_set, fragments, seen)
        elif isinstance(node, FragmentSpreadNode) and node.name.value in fragments and node.name.value not in seen:
            total += _root_field_count(fragments[node.name.value].selection_set, fragments, seen | {node.name.value})
    return total


def prepare(body: bytes | str | None) -> Prepared:
    """Checks the request before any quota is spent. Raises ApiError(400/413)."""
    raw = body.encode("utf-8") if isinstance(body, str) else (body or b"")
    if len(raw) > MAX_BODY_BYTES:
        raise ApiError(413, f"The request is larger than {MAX_BODY_BYTES} bytes")
    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ApiError(400, "The request body is not valid JSON") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("query"), str):
        raise ApiError(400, 'Send {"query": "...", "variables": {...}}')
    query = payload["query"]
    if len(query) > MAX_QUERY_CHARS:
        raise ApiError(413, f"The query is longer than {MAX_QUERY_CHARS} characters")
    variables = payload.get("variables") or {}
    if not isinstance(variables, dict):
        raise ApiError(400, "variables must be an object")
    operation_name = payload.get("operationName")
    if operation_name is not None and not isinstance(operation_name, str):
        raise ApiError(400, "operationName must be a string")
    try:
        document = parse(query, max_tokens=2000)
    except GraphQLError as exc:
        raise ApiError(400, f"GraphQL syntax error: {exc.message}") from exc
    errors = validate(SCHEMA, document, specified_rules)
    if errors:
        raise ApiError(400, "; ".join(error.message for error in errors[:5]))
    operations = [item for item in document.definitions if isinstance(item, OperationDefinitionNode)]
    fragments = {item.name.value: item for item in document.definitions if isinstance(item, FragmentDefinitionNode)}
    if operation_name:
        operations = [item for item in operations if item.name and item.name.value == operation_name]
    if len(operations) != 1:
        raise ApiError(400, "Send exactly one query operation per request")
    operation = operations[0]
    if operation.operation != OperationType.QUERY:
        raise ApiError(400, "Only queries are allowed; the API is read-only")
    depth, count = _depth_and_count(operation.selection_set, fragments, 1, frozenset())
    if depth > MAX_DEPTH:
        raise ApiError(400, f"The query is nested deeper than {MAX_DEPTH} levels")
    if count > MAX_FIELDS:
        raise ApiError(400, f"The query selects more than {MAX_FIELDS} fields")
    roots = _root_field_count(operation.selection_set, fragments, frozenset())
    if roots > MAX_ROOT_FIELDS:
        raise ApiError(400, f"At most {MAX_ROOT_FIELDS} root fields (tabs) per request")
    return Prepared(document, variables, operation_name, roots)


def _plain(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return value


def _movements(info: Any, **args: Any) -> list[dict[str, Any]]:
    context: Context = info.context
    kind = args["kind"]
    layer = args["layer"]
    table = TABLES.get((kind, layer))
    alias = info.path.key
    if table is None:
        raise GraphQLError(f"{alias}: there is no {kind.lower()} {layer.lower()} table")
    months = args.get("months")
    if months is None and layer == "CLOSED":
        months = DEFAULT_CLOSED_MONTHS
    if months is not None and not 1 <= months <= 120:
        raise GraphQLError(f"{alias}: months must be between 1 and 120")
    requested = args.get("limit")
    if requested is not None and requested < 1:
        raise GraphQLError(f"{alias}: limit must be at least 1")
    budget = context.rows_left if requested is None else min(requested, context.rows_left)
    if budget <= 0:
        context.truncated.append(alias)
        return []
    upcoming = bool(args.get("upcomingOnly")) and layer == "FUTURE"
    exclude = bool(args.get("excludeTransfers"))
    context.cur.execute(
        """
        SELECT public.graphql_rows(
            %s, %s,
            CASE WHEN %s THEN (NOW() AT TIME ZONE 'America/Mexico_City')::DATE END,
            NULL, %s, %s
        )
        """,
        (table, months, upcoming, budget + 1, exclude),
    )
    rows = context.cur.fetchone()[0] or []
    if isinstance(rows, str):
        rows = json.loads(rows)
    if len(rows) > budget:
        context.truncated.append(alias)
        rows = rows[-budget:]
    context.rows_left -= len(rows)
    context.rows += len(rows)
    # sql/016 fields; a row without them (016 not applied yet) is not a transfer.
    return [
        {"is_internal_transfer": False, **{key: _plain(value) for key, value in row.items()}} for row in rows
    ]


def _usage(info: Any) -> dict[str, Any]:
    usage = info.context.usage
    return {
        "plan_code": usage.get("plan_code") or "",
        "used": usage.get("used", 0),
        "limit": usage.get("limit", 0),
        "remaining": usage.get("remaining", 0),
        "window": usage.get("window", "week"),
        "resets_at": str(usage.get("resets_at", "")),
        "max_rows": usage.get("max_rows", 0),
    }


ROOT = {"movements": _movements, "usage": _usage}


def run(prepared: Prepared, cur: psycopg.Cursor[Any], usage: dict[str, Any]) -> tuple[dict[str, Any], Context]:
    """Executes a prepared query inside the caller's strm_app session."""
    context = Context(cur=cur, usage=usage, rows_left=int(usage.get("max_rows") or 5000))
    result = execute(
        SCHEMA,
        prepared.document,
        root_value=ROOT,
        context_value=context,
        variable_values=prepared.variables,
        operation_name=prepared.operation_name,
    )
    body: dict[str, Any] = {"data": result.data}
    if result.errors:
        body["errors"] = [{"message": error.message, "path": error.path} for error in result.errors]
    return body, context


def usage_public(usage: dict[str, Any]) -> dict[str, Any]:
    keys = ("plan_code", "used", "limit", "remaining", "window", "resets_at", "max_rows")
    return {key: _plain(usage.get(key)) for key in keys}


def handle(
    conn: psycopg.Connection[Any],
    authorization: str | None,
    body: bytes | str | None,
    at: datetime | None = None,
) -> tuple[int, dict[str, Any], dict[str, str]]:
    """One HTTP request: checks, quota, read-only session, execution, log."""
    try:
        token = bearer_token(authorization)
        prepared = prepare(body)
    except ApiError as exc:
        return exc.status, {"error": exc.message}, {}
    try:
        with conn.cursor() as cur:
            if at is None:
                cur.execute("SELECT public.api_consume_call(%s, 'graphql')", (token,))
            else:
                cur.execute("SELECT public.api_consume_call_at(%s, 'graphql', %s)", (token, at))
            usage = cur.fetchone()[0]
        conn.commit()
    except psycopg.Error as exc:
        conn.rollback()
        if exc.sqlstate == "28000":
            return 401, {"error": "invalid or revoked API token"}, {}
        raise
    if not usage.get("ok"):
        return 429, over_quota_body(usage), retry_after(usage, at)
    status_text = "error"
    rows = 0
    try:
        with conn.cursor() as cur:
            cur.execute("SET TRANSACTION READ ONLY")
            cur.execute("SELECT set_config('app.user_id', %s, true)", (str(usage["user_id"]),))
            cur.execute("SELECT set_config('app.tenant_id', %s, true)", (str(usage["tenant_id"]),))
            cur.execute("SET LOCAL ROLE strm_app")
            payload, context = run(prepared, cur, usage)
        conn.commit()
        rows = context.rows
        payload["extensions"] = {
            "usage": usage_public(usage),
            "rows": context.rows,
            "truncated": context.truncated,
        }
        encoded = json.dumps(payload, default=str)
        if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
            return (
                413,
                {"error": "The response is too large; ask for fewer months, rows or columns", "usage": usage_public(usage)},
                {},
            )
        status_text = "error" if payload.get("errors") else "ok"
        return 200, payload, {}
    finally:
        conn.rollback()
        with conn.cursor() as cur:
            cur.execute("SELECT public.api_finish_call(%s, %s, %s)", (usage["call_id"], status_text, rows))
        conn.commit()


def over_quota_body(usage: dict[str, Any]) -> dict[str, Any]:
    window = "day" if usage.get("window") == "day" else "week"
    limit = usage.get("limit", 0)
    resets = _plain(usage.get("resets_at"))
    if limit == 0:
        message = f"Your {usage.get('plan_name') or 'current'} plan does not include API calls."
    else:
        plural = "call" if limit == 1 else "calls"
        message = (
            f"API limit reached: your {usage.get('plan_name') or ''} plan allows {limit} {plural} per {window}. "
            f"It resets at {resets}."
        ).replace("your  plan", "your plan")
    return {
        "error": message,
        "code": "QUOTA_EXCEEDED",
        "limit": limit,
        "used": usage.get("used"),
        "window": window,
        "resets_at": resets,
    }


def retry_after(usage: dict[str, Any], at: datetime | None) -> dict[str, str]:
    resets = usage.get("resets_at")
    if not isinstance(resets, str):
        return {}
    try:
        reset_at = datetime.fromisoformat(resets)
    except ValueError:
        return {}
    now = at or datetime.now(reset_at.tzinfo)
    return {"retry-after": str(max(int((reset_at - now).total_seconds()), 1))}
