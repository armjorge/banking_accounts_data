# GraphQL API for Google Sheets (sql/015, sql/016, sql/017)

A read-only GraphQL endpoint over the five master tables, joined with the movement
attributes (`debit_d` / `credit_d`). It is meant for Google Sheets: one "Refresh all"
sends **one** request that fills every tab.

- URL: `POST {api-url}/graphql` (SSM parameter `/{prefix}/graphql-url`). Locally:
  `POST http://127.0.0.1:8765/graphql` from `apps/statements/local_api.py`.
- Auth: `Authorization: Bearer bst_…` — a per-user API token created on the app's
  **API tokens** page. Not the Cognito sign-in.
- Code: `infra/lambda/graphql.ts` (Lambda handler), `infra/lambda/graphql-core.ts`
  (schema, limits, resolvers), `apps/statements/graphql_api.py` (Python twin used by
  `local_api.py` and the tests), `integrations/google_sheets/Code.gs` (Apps Script).

## Schema

```graphql
enum Kind { DEBIT CREDIT ASSET }
enum Layer { CLOSED OPEN FUTURE }

type Query {
  movements(kind: Kind!, layer: Layer!, months: Int, upcomingOnly: Boolean, excludeTransfers: Boolean, limit: Int): [Movement!]
  usage: Usage!
}
```

`movements` reads one master table:

| kind   | layer  | table                    |
|--------|--------|--------------------------|
| DEBIT  | CLOSED | `master_debit_closed_f`  |
| DEBIT  | OPEN   | `master_debit_open_f`    |
| CREDIT | CLOSED | `master_credit_closed_f` |
| CREDIT | OPEN   | `master_credit_open_f`   |
| CREDIT | FUTURE | `master_credit_future_f` |
| ASSET  | CLOSED | `master_closed_aaccandass_f` (sql/017, `docs/investments_assets.md`) |
| ASSET  | OPEN   | `master_open_aaccandass_f` (sql/019, current period) |

`DEBIT`/`FUTURE` and `ASSET`/`FUTURE` are errors for that field only (the other fields of the request still
answer).

Arguments:

- `months` — keep rows with `txn_date` on or after *today − months* (America/Mexico_City).
  1–120. Default: **12 for CLOSED**, no limit for OPEN and FUTURE.
- `upcomingOnly` — FUTURE only: rows dated after today.
- `excludeTransfers` — (sql/016) leave out movements linked as a transfer between two of
  your accounts (`docs/transfers.md`). Default false: every row comes back with its
  `is_internal_transfer` flag, so the sheet can also filter by the column.
- `limit` — at most this many rows for the field (the newest are kept).

`Movement` fields — pick the columns you want, as GraphQL selection:
`row_hash table layer kind row_id account_id account_number bank_id bank_name
period_start period_end txn_date concept concept_sk abonos cargos amount
occurrence file_name attribute_1 attribute_2 attribute_3`, and since sql/016
`is_internal_transfer transfer_link_hash transfer_role transfer_type transfer_source
transfer_counterpart_account`, and since sql/017 `source_profile balance`.
`balance` (asset rows only) is the account balance after the row, counted over the full
history even when `months` cuts the rows; `source_profile` is the statement profile, or
for asset rows the entry source (`upload`, `manual`, `adjustment`). Asset rows store
`abonos` and `cargos` both positive (in/gain and out/loss).
`attribute_N` is always text: for an attribute bound to a list (`docs/dimensions.md`) it
is the item **name** (a rename shows on the next refresh).
`is_internal_transfer` is true when the movement is one side of an active transfer link;
`transfer_role` is `sending`/`receiving`, `transfer_type` `same_bank`/`inter_bank`,
`transfer_source` `auto`/`manual`, `transfer_counterpart_account` the other account's
number (all null when not linked).
Dates are ISO strings; amounts follow `docs/standard_masters.md` (debit `cargos ≤ 0` and
`amount = abonos + cargos`; credit and assets `cargos ≥ 0` and `amount = abonos - cargos`).
`file_name` and `source_profile` come from the upload, not from the master row. New fields:
`entry_source` (upload / manual / opening / adjustment) and `cutoff_id`; `balance` is filled
for every kind.

`usage { plan_code used limit remaining window resets_at max_rows }` returns the quota
state after this call (it costs nothing extra; it is part of the same request).

Rows come back oldest first.

### One request for every tab (aliases)

```graphql
query RefreshAll {
  t0: movements(kind: DEBIT, layer: CLOSED, months: 12) { txn_date concept_sk abonos cargos attribute_1 }
  t1: movements(kind: DEBIT, layer: OPEN) { txn_date concept_sk abonos cargos amount }
  t2: movements(kind: CREDIT, layer: CLOSED, months: 4) { txn_date concept_sk abonos cargos }
  t3: movements(kind: CREDIT, layer: OPEN) { txn_date concept_sk cargos }
  t4: movements(kind: CREDIT, layer: FUTURE) { txn_date concept_sk cargos attribute_2 }
  usage { used limit window resets_at }
}
```

Response: `{"data": {"t0": [...], ..., "usage": {...}}, "extensions": {"usage": {...},
"rows": 18, "truncated": []}}`. Field errors are listed in `errors` as usual.

## Quotas (per plan, per user)

Stored in `public.plans_d` — edit the table, nothing is hard-coded:

| column            | meaning                                                         |
|-------------------|-----------------------------------------------------------------|
| `api_calls_limit` | GraphQL requests per user per window. `0` turns the API off.     |
| `api_window`      | `day` or `week` (calendar windows in America/Mexico_City; weeks start Monday 00:00). |
| `api_max_rows`    | most rows in one response, all fields together (default 5000).   |

Defaults set by 015 (only where the columns are empty):

| plan    | calls | window | note                       |
|---------|-------|--------|----------------------------|
| Free    | 1     | week   | as requested               |
| Entry   | 1     | week   | **placeholder — confirm**  |
| Plus    | 3     | day    | **placeholder — confirm**  |
| Premium | 3     | day    | as requested               |

Example change: `UPDATE public.plans_d SET api_calls_limit = 2 WHERE plan_code = 'entry';`

The old `plans_d.monthly_api_quota` column is unused (comment on the column says so).

**Re-applying migrations does not wipe these values.** `006`'s plan upsert
(`ON CONFLICT (plan_code) DO UPDATE`) lists only its own columns, so it leaves
`api_calls_limit`, `api_window` and `api_max_rows` alone; `015` only fills them where
they are NULL. (006 *does* reset the columns it lists — display name, account caps,
`monthly_api_quota`, `curated_csv_backup` — as before.) `004` drops `plans_d` only when
the banking tables do not exist yet (first install). A test re-applies the banking DDL
(006/007; 004 is skipped) and 011–015 and checks an edited quota survives.

### How a call is counted

One HTTP request = one call, however many root fields (tabs) it has.

1. Size and shape checks (below). A bad request gets 400/413 and **is not counted**.
2. `public.api_consume_call(token, 'graphql')` (SECURITY DEFINER, one transaction):
   finds the token (sha256, not revoked) → takes a per-user advisory lock
   (`pg_advisory_xact_lock`) → counts the user's `accepted`/`ok`/`error` calls in the
   current window → inserts an `accepted` row, or a `rejected` row when the limit is
   reached. Concurrent requests queue on the lock, so the limit cannot be passed
   (a test fires 12 at once on a 3/day plan: exactly 3 pass).
3. Over the limit → **HTTP 429** with `Retry-After` (seconds) and:

   ```json
   {"error": "API limit reached: your Free plan allows 1 call per week. It resets at 2026-11-16T00:00:00-06:00.",
    "code": "QUOTA_EXCEEDED", "limit": 1, "used": 1, "window": "week",
    "resets_at": "2026-11-16T00:00:00-06:00"}
   ```

4. Otherwise the query runs in a `READ ONLY` transaction as `strm_app` with
   `app.tenant_id` / `app.user_id` set from the token, so row level security applies.
5. `public.api_finish_call` stores `ok` or `error` and the number of rows.

The count is per **user** (all of the user's tokens share it); each log row also keeps
the `token_id`. `rejected` rows do not count. An invalid or revoked token is 401 and is
not logged.

Call log: `public.api_usage_f (call_id, tenant_id, user_id, token_id, called_at,
operation, status, rows_returned)`, row level security per tenant and user (read-only for
`strm_app`). The app's **API tokens** page shows calls used / limit / reset time and the
last 10 calls (`public.api_usage_summary()`).

`api_consume_call_at(token, operation, at)` is the same with an explicit clock, for
tests; it is not granted to `strm_app`.

## Guardrails

| limit                         | value                         | where |
|-------------------------------|-------------------------------|-------|
| request body                  | 16 KB → 413                   | Lambda / local API, before parsing |
| query text                    | 8000 characters, 2000 tokens  | parser |
| operations                    | exactly one `query` (no mutations, no subscriptions) | |
| depth                         | 3                             | custom check (fragments included) |
| fields selected               | 250                           | custom check |
| root fields (tabs)            | 8 (aliases count)             | custom check |
| introspection                 | off (`__schema`, `__type`)    | this page documents the schema |
| rows per response             | `plans_d.api_max_rows` (5000) | resolvers share one budget; cut fields are listed in `extensions.truncated` |
| response size                 | 5.5 MB → 413                  | Lambda payload limit is 6 MB |
| SQL statement timeout         | 10 s                          | Lambda pg client |
| API Gateway throttling        | 5 req/s, burst 10 on `POST /graphql` | stage route settings; CDK context `graphqlRateLimit` / `graphqlBurstLimit` |

All of these run **before** the quota is spent except the row budget and response size.

## Tokens

- Created on the **API tokens** page (`POST /api-tokens`, `public.create_api_token`):
  `bst_` + 48 hex characters, shown **once**. Only `sha256(token)` and the first 10
  characters are stored (`public.api_tokens_d`). Scope is `read` only.
- At most 5 active tokens per user. Revoke with the button (`DELETE /api-tokens/{id}`,
  `public.revoke_api_token`) — the next call gets 401.
- `strm_app` cannot read the `token_sha256` column.

## Google Sheets (Apps Script)

`integrations/google_sheets/Code.gs`:

1. In the sheet: Extensions › Apps Script, paste the file, save, reload the sheet.
2. Menu **Bank data › Set API URL** (`…/graphql`) and **Set API token**. Both are kept in
   Script Properties (not in a cell).
3. Optional **Create config tab**: one row per tab — tab name, kind, layer, months,
   comma-separated columns, and (sql/016) `exclude_transfers` (`yes` = send
   `excludeTransfers: true` for that tab; blank = keep every row). Without it the seven
   default tabs are used (sql/017 adds `master_closed_aaccandass_f`, ASSET / CLOSED, 12
   months; sql/019 adds `master_open_aaccandass_f`, ASSET / OPEN; both include `balance`
   and `source_profile`) (they keep every row; add `is_internal_transfer` to the columns
   to filter in the sheet).
4. **Refresh all**: builds one query with aliases `t0…tN` plus `usage`, makes **one**
   `UrlFetchApp.fetch`, then clears each tab and writes headers + rows. On 429 it shows
   the message with the reset time and leaves the tabs as they were. The toast shows
   "API calls: 1 of 1 this week. Resets at …". **Show last usage** reads the saved usage
   without calling the API.

Unknown columns, a debit future tab, an ASSET tab that is not CLOSED or more than 7 tabs fail in the script before any call.

## Local

```bash
DATABASE_URL=postgresql:///strm_preview PYTHONPATH=apps uv run python -m statements.local_api
curl -s -X POST http://127.0.0.1:8765/graphql \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"query":"{ usage { used limit resets_at } }"}'
```

## Tests

`apps/statements/tests/test_dimensions_graphql.py` (quota hit and 429 body, reset next
window, per-user across tokens, 12 concurrent calls on a limit of 3, months filter,
column selection, row cap, RLS, token revoke, plan edits surviving re-apply, the Apps
Script query against the database), `test_lists_transfers_completeness.py` (item names
and the transfer flag / `excludeTransfers` through GraphQL), `test_graphql_node_016.py`
(the TypeScript core passes `excludeTransfers`, the config tab column) and
`test_graphql_node.py` (the TypeScript core gives
the same answers as the Python twin; Apps Script makes one fetch and writes the tabs).
