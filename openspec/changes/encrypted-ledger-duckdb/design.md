# Design

## Context

See proposal.md for why. Movement rows live in nine fact tables under `sql/006_statement_flow.sql`, `sql/011_open_future_ledgers.sql`, `sql/017_investments_assets.sql`, and `sql/019_account_types_open_assets.sql`. Ingest, GraphQL, and the signed-in pages write and read those tables directly. `plans_d` already stores GraphQL allowances: Free and Entry 1 per week, Plus and Premium 3 per day, 5000 rows. The published API is `infra/lambda/statements.ts`; `apps/statements/local_api.py` is the preview twin.

## Goals / Non-Goals

**Goals:**

- One ledger for the nine movement tables, with a one-time copy and no further writes to the old tables.
- Ciphertext for the sensitive fields, with dates and ownership still filterable.
- A server-side DuckDB window per person, refreshed at row, period, or full-table scope.
- A query view and a period export that follow the specs.

**Non-Goals:**

- Encrypting dimension, account, bank, or list tables.
- Folding `credit_plan_closed_f` into the ledger.
- Shipping the data key to the browser, or keeping DuckDB as a durable store.
- Changing the GraphQL quota numbers.

## Decisions

### One ledger table, old tables left in place

Add `public.movement_ledger_f` with `kind` (`debit`, `credit`, `asset`) and `state` (`closed`, `open`, `future`), plus the shared movement columns and `row_hash`. A migration copies the nine tables, then ingest and edit functions write only the ledger. The old tables stay for rollback and are not dropped in this change. Readers of movements use the ledger.

Alternative: a view that unions the old tables. Rejected because the request replaces the multiple-table design, and encryption needs one write path.

### Envelope encryption, dates left in the clear

Each person has a data key wrapped by an application master key kept outside Postgres (the environment secret store). The API encrypts concept, amounts, account number, file name, and note before insert. `user_id`, `tenant_id`, `account_id`, kind, state, `txn_date`, and `row_hash` stay in the clear so the three-month select does not decrypt older rows. Decryption happens in the API, not in SQL.

Alternative: encrypt `txn_date` too. Rejected for this change because loading the window would decrypt the whole history. Alternative: Postgres disk encryption only. Rejected because a SQL reader would still see plaintext.

### DuckDB stays in the API process

The statements API holds one DuckDB per signed-in person, with external file access disabled and only that person's window table attached. The file is temporary and is rebuilt from decrypted ledger rows after a restart. Row edits replace those `row_hash` values. A file or period replace deletes and reinserts the dates in that period that still fall inside the window. Anything else, including a month rollover, rebuilds the table and then drops rows outside the window.

Queries run as read-only SQL on that connection. A statement that is not a single read is rejected before it counts. Results are capped at 5000 rows.

Alternative: DuckDB in the browser. Rejected because the data key would have to leave the server.

### A separate usage counter

Add a usage table keyed by person and window (week for Free and Entry, day for Plus and Premium). The query view reads `plans_d` for the allowance and displays the remainder. GraphQL keeps `api` usage as it is.

### Export decrypts the chosen period on demand

Normalized export decrypts ledger rows for the selected period, even when that period is outside the DuckDB window, writes one CSV, and adds the stored PDFs for that period. It does not insert those rows into the window. Raw export copies the original upload objects for that period from the curated bucket, whole. Manual rows with no source file produce the empty-raw message.

## Risks / Trade-offs

- [Master key loss makes ciphertext unreadable] → The key lives in the environment secret store, and the migration does not delete the old plaintext tables until a later, explicit drop.
- [Lambda and preview API drift on encrypt and refresh] → Shared SQL for the copy and the window select; Python tests cover copy fidelity, ciphertext, refresh scope, quota, and export shape. The TypeScript handler calls the same SQL.
- [A person-controlled SQL query escapes the window] → DuckDB external access stays off, and only that person's table is attached.
- [Three-month window misses an older screen] → Screens for an older period decrypt that period for the request and do not keep it in DuckDB.

## Migration Plan

Ship the SQL copy and the dual-write stop before the new pages. Deploy the API, then the site. Rollback is the previous API: the old tables still hold the pre-copy rows, and ledger writes made after the copy would need a reverse copy before those rows are visible on the old code. Do not drop the old tables in the rollback window.

## Open Questions

None. The table set, the fields left in the clear, the refresh scopes, and the plan numbers are fixed by the proposal and the specs.
