# Proposal

## Why

Statement and asset movements are stored in several master tables with different columns, in plaintext. A person should see their own rows decrypted, while the database holds ciphertext, and should be able to query and export a period without a separate copy of each master.

## What Changes

- **BREAKING**: Replace the movement master tables with one ledger table. The tables in scope are `master_debit_closed_f`, `master_credit_closed_f`, `master_debit_open_f`, `master_credit_open_f`, `master_debit_future_f`, `open_debit_f`, `open_credit_f`, `master_closed_aaccandass_f`, and `master_open_aaccandass_f`. Existing rows are copied once. New writes go only to the new table.
- Store the sensitive ledger fields as ciphertext in Postgres. The signed-in app shows plaintext.
- Keep a transient DuckDB table of the signed-in person's decrypted rows for the last three calendar months, including the current month. A row edit refreshes those rows, a period or file change refreshes that period, and anything that cannot be mapped rebuilds the whole window.
- Add a marketed query view over that DuckDB table. Each plan has its own query allowance, separate from the GraphQL allowance.
- Add an export view for one period: a normalized CSV plus the period's PDFs, or the raw source files whole. Raw export does not slice a file.

Assumptions:

- Dimension tables (`debit_d`, `credit_d`, `master_closed_aaccandass_d`), accounts, banks, lists, and `credit_plan_closed_f` (no longer written) stay as they are. The new ledger keeps `row_hash` so dimensions still attach.
- DuckDB query allowances match the GraphQL numbers already on `plans_d`: Free and Entry 1 per week, Plus and Premium 3 per day, at most 5000 rows per result. The counters are separate.
- Dates use the America/Mexico_City calendar.

## Capabilities

### New Capabilities

- `unified-movement-ledger`: One movement table for debit, credit, open, future, and asset rows, with the same values readers get today.
- `encrypted-movement-storage`: Ciphertext at rest for sensitive ledger fields, plaintext only for the signed-in owner.
- `duckdb-recent-window`: A per-person decrypted window of the last three months, refreshed at the smallest scope that stays correct.
- `metered-duckdb-query`: A query view whose use is limited by the plan.
- `period-file-export`: A period download in normalized or raw form. Raw downloads are whole source files only.

### Modified Capabilities

- None. `openspec/specs/` has no capabilities yet.

## Impact

- New SQL migration and a one-time copy from the movement masters. Statement ingest, asset edits, GraphQL, and the signed-in pages read and write the new table.
- Key handling for encryption. Database dumps and replicas contain ciphertext, not the amounts and concepts.
- A transient DuckDB file or memory table per signed-in person, not a durable database.
- The backup workbook in `console-foundation-parity`, if that change is applied, must export plaintext assembled after decrypt, not the ciphertext columns.
