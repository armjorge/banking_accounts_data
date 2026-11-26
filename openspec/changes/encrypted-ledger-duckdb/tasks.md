# Tasks

## 1. Unified ledger

- [ ] 1.1 Add `movement_ledger_f` and a copy from the nine movement tables that preserves `row_hash`, dates, amounts, concept, account, and file identity. Verify a Postgres test that a closed debit row and a closed asset row land in the one table with the right kind and state, and that the copied debit row matches the source values.
- [ ] 1.2 Switch statement and asset writes to the ledger and point movement reads, including dimension attachment by `row_hash`, at it. Verify an upload test inserts ledger rows only, and an existing attribute still resolves for the copied `row_hash`.

## 2. Encryption

- [ ] 2.1 Encrypt concept, amounts, account number, file name, and note with a per-person data key wrapped by a master key outside Postgres. Leave `user_id`, `tenant_id`, `account_id`, kind, state, `txn_date`, and `row_hash` in the clear. Verify a SQL read of the ledger shows ciphertext for the sensitive fields, and the signed-in API returns plaintext only to the owner.

## 3. DuckDB window

- [ ] 3.1 Build a per-person transient DuckDB table for the current month and the two previous calendar months in America/Mexico_City, decrypted, with external access disabled. Verify a test that a current-month row is present, a four-month-old row is absent, another person's row is absent, and a restart rebuilds the table from the ledger.
- [ ] 3.2 Refresh one row on a row edit, the affected dates on a file or period replace, and the whole table when the change cannot be mapped or the month boundary moves. Verify tests for each of those three scopes, and that the table still holds only the three-month window afterward.

## 4. Metered query view

- [ ] 4.1 Add the query view and a usage counter separate from GraphQL. Enforce Free and Entry at 1 per week, Plus and Premium at 3 per day, and 5000 rows, using America/Mexico_City. Show the plan, the remainder, and the reset. Verify tests that a read returns window rows, a write is rejected and not counted, a query past the allowance returns no rows and names the reset, a GraphQL remainder is unchanged, and a result stops at 5000 rows.

## 5. Period export

- [ ] 5.1 Add the export view. Normalized downloads a CSV of the person's decrypted ledger rows for the period plus that period's PDFs, without inserting those rows into DuckDB. Raw downloads only the whole source files for the period. Verify tests for a normalized CSV-plus-PDF download, a raw file that matches the stored object byte for byte, no control for a raw row subset, another person's files absent, raw with no source file, and a header-only CSV when the period has no movements.

## Workflow follow-up

- Archive this change after the implementation is reviewed and the specs are synced.
