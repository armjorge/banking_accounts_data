# Investments & Assets (sql/017)

> **sql/018:** opening balance, monthly check, balance and the column map are now generic (`add_opening_balance`, `reconcile_account`, `account_balance_home`, `column_map_preview`); the asset functions wrap them. Asset rows point at a calendar-month `cutoff_id` (`period_source = 'ledger'`).

Accounts whose value is not a bank statement: Infonavit, Afore, CETES, GBM, cash, a car.
Savings, Investment, Asset and Credit contract (sql/019) share these tables. Each account
has its movements in `master_closed_aaccandass_f` (dates outside the current period) and
`master_open_aaccandass_f` (the current period, replaced by the next open upload), labels in
`master_closed_aaccandass_d`, and can be reconciled at any date against the balance the
institution shows, so the **balance at any point in time** is the sum of its rows.

Code: `sql/017_investments_assets.sql`, routes in `infra/lambda/statements.ts`
(`dispatch017`) and `apps/statements/local_api.py` (`dispatch_017`), page
`web/assets.js` (menu **Investments & Assets**), generic spreadsheet reader
`strmXlsxToRows` in `web/xlsx_to_csv.js`. Tests: `test_investments_assets.py`,
`test_sql_017_static.py`.

## Accounts

- Account types `investment` and `asset` (`account_types_d.ledger_kind = 'asset'`, no
  cutoff day, no payment window).
- An account belongs to a bank or an **institution** (`banks_d.is_institution`). Seeded:
  Infonavit, Afore, Cetesdirecto, GBM, Efectivo, Bienes personales. The page can name a
  new institution; it is added to `banks_d` (shared catalogue) without a statement
  profile.
- Own plan limit `plans_d.max_asset_accounts` (free 2, entry 3, plus 10, premium 20).
  Asset accounts do not count toward `max_total_accounts` / debit / credit limits.
- The account number is optional: a blank one becomes `9` + 5 digits (unique per user),
  because `bank_accounts_d.account_number` must be digits.
- The Statements page, upload completeness and the statement bank picker leave asset
  accounts out.

Function: `create_asset_account(bank_id, institution, a_type_id, account_name, account_number)`.

## The table: `master_closed_aaccandass_f`

Four core columns:

| column     | meaning                                                   |
|------------|-----------------------------------------------------------|
| `txn_date` | date of the movement                                       |
| `concept`  | text; `concept_sk` is derived as in the statement tables   |
| `abonos`   | money in or gain, stored **positive**                      |
| `cargos`   | money out or loss, stored **positive**                     |

Generated like the other masters: `row_hash = movement_row_hash_v2(user_id, account_id,
bank_id, txn_date, concept_sk, abonos, cargos, occurrence)` (`docs/row_hash.md`);
`amount = abonos − cargos`; `period_start`/`period_end` = calendar month of `txn_date`;
`account_number`, `bank_name`, `bank_id`, `user_id`, `tenant_id` come from the account,
never from the file. `entry_source`: `upload` (with `file_id`), `manual`,
`opening` or `adjustment`. `file_name` is the upload's chosen name, read in
`movement_keys_v`, not a column of the master. Rows are never updated (trigger); an uploaded row
goes away only by deleting its file.

Running balance: view `master_closed_aaccandass_balance_v` (balance after each row, by
date then row id). Functions: `aaccandass_balance(account_id, as_of)`,
`aaccandass_balances(as_of, months)` (month ends per account plus the total),
`aaccandass_rows(account_id, from, to, q, limit, offset)`, `aaccandass_home(as_of)`.

## Upload with a column map

1. Pick the account, choose a CSV or XLSX (spreadsheets are read in the browser; date
   cells become `YYYY-MM-DD`; pick the sheet when there are several).
2. The page sends the text to `POST /assets/preview` with the map so far; the first
   answer has the headers, the first lines and a guessed map.
3. Map the columns:

   | key           | value                                                              |
   |---------------|--------------------------------------------------------------------|
   | `header_row`  | line of the headers (default 1; GBM exports use 2)                 |
   | `txn_date`    | date column (required)                                             |
   | `date_format` | `DMY` (default), `MDY` or `YMD` for dates like 05/09/2026          |
   | `abono`       | money in / gain column                                             |
   | `cargo`       | money out / loss column; none (or `{"constant": 0}`) = always 0     |
   | `amount`      | instead of abono/cargo: one signed column (> 0 abono, < 0 cargo)   |
   | `concept`     | `A || ' - ' || B` (quoted text is literal) or a list of columns     |

   Headers match ignoring case, accents and spaces. A negative abono is stored as a
   cargo; cargos are stored as absolute values. Dates: ISO, d/m/y (two-digit years are
   20xx), Excel serial numbers, Spanish month names. Lines without a date, with an
   unreadable date or with a zero amount are skipped and listed with the reason. A blank
   concept becomes "Movimiento".
4. The preview shows every mapped row (new / already stored / skipped), the totals and
   the balance before and after. Nothing is stored yet.
5. **Save** calls `POST /assets/uploads` (`ingest_aaccandass_upload`): the same file twice
   is refused; rows already stored (same `row_hash`, e.g. an overlapping export) are
   counted as duplicates; a template name saves the map for the account
   (`aaccandass_templates_d`, updated when the name exists) and the next file opens with
   it.

Example (Infonavit "aportaciones" export): `txn_date = Fecha de pago`,
`abono = Aportación`, `cargo = none`,
`concept = Num. De Registro Patronal || ' - ' || Nombre de la empresa`.

Vault: when the plan keeps curated backups, the CSV is written once to
`curated/{tenant}/{YYYY-MM}_{account}_{Bank}_inv.csv` (month of the last movement; `_v2`…
when taken) with the manifest `curated/{tenant}/manifest/…_inv.csv.json` (map, headers,
counts, account). Same registry and Object Lock rules as statement files
(`curated_vault_keys_d`, sql/013). Deleting a file writes a delete marker; the vault
object stays.

## Manual rows

For sources that only give a PDF (CETES): `POST /assets/rows` (`add_aaccandass_row`) with
date, concept, abono or cargo, note. Example, Cetesdirecto:

| date       | concept                | abono      | cargo      | balance    |
|------------|------------------------|------------|------------|------------|
| 2026-09-01 | Saldo inicial          | 395,240.86 |            | 395,240.86 |
| 2026-09-30 | Rendimiento septiembre | 1,922.17   |            | 397,163.03 |
| 2026-10-13 | EGREFVO                |            | 188,000.00 | 209,163.03 |
| 2026-10-31 | Rendimiento octubre    | 1,650.65   |            | 210,813.68 |

Manual and adjustment rows can be deleted (`DELETE /assets/rows/{rowHash}`).

## Reconcile (balance check)

`POST /assets/reconcile` (`reconcile_aaccandass(account_id, as_of, reported_balance,
adjust_date, concept, note)`): the balance the institution shows at `as_of` minus the sum
of the rows up to that date becomes **one** `adjustment` row (abono when positive, cargo
when negative), dated `adjust_date` (default `as_of`; use an earlier date to make it an
opening balance). A zero difference stores no row. Every check is kept in
`aaccandass_checks_f` (reported, tracked, difference, adjustment row).

- Infonavit: the export adds up to 135,661.56; the account shows 438,225.05 → adjustment
  abono 302,563.49 (the history before the export).
- GBM with only a portfolio snapshot (14,467.34): reconcile with an earlier adjustment
  date → an opening row of 14,467.34.
- CETES above: checks on 2026-09-30 (397,163.03) and 2026-10-31 (210,813.68) match.

## Dimensions, lists, GraphQL, Google Sheets

- `movement_keys_v` and `movement_attributes_v` include both tables as kind `asset`
  (layer `closed` or `open`). They share `master_closed_aaccandass_d`. The Dimensions
  page has an **Investments & assets** group; attributes, list binding and list usage
  counts work as for debit and credit. A pure transfer side (money out with no abono, or
  the reverse) is detected on both tables.
- GraphQL: `movements(kind: ASSET, layer: CLOSED)` reads `master_closed_aaccandass_f`
  and `layer: OPEN` reads `master_open_aaccandass_f`.
- Sheets (`Code.gs`): `master_closed_aaccandass_f` (ASSET / CLOSED, last 12 months) and
  `master_open_aaccandass_f` (ASSET / OPEN).

## Routes

`GET /assets`, `GET /assets/balances`, `POST /assets/accounts`, `GET|POST /assets/rows`,
`DELETE /assets/rows/{rowHash}`, `POST /assets/reconcile`, `POST /assets/preview`,
`POST /assets/uploads`, `DELETE /assets/uploads/{uploadId}`,
`DELETE /assets/templates/{templateId}`.

## Deploy

1. Apply `sql/016_lists_completeness_transfers.sql` first if it is not on Neon yet, then
   `sql/017_investments_assets.sql` (safe to run twice). `sql/006` now also accepts the
   asset types, so re-running the banking DDL from the console still works; re-apply
   011–017 afterwards as before.
2. Deploy the environment stack (new `/assets…` routes; GraphQL Lambda with `ASSET`).
3. Publish the site (`web/assets.js`, `web/dimensions.js`, `web/xlsx_to_csv.js`).
4. Paste the new `integrations/google_sheets/Code.gs` (sixth tab).
