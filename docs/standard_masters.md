# Standard master tables, balances, banks and the column map (sql/018)

## One column layout for the master tables

`master_debit_closed_f`, `master_debit_open_f`, `master_credit_closed_f`,
`master_credit_open_f`, `master_credit_future_f`, `master_closed_aaccandass_f` and
`master_open_aaccandass_f` (sql/019) start with
the same 14 columns, in this order:

| Group | Columns |
| --- | --- |
| key | `row_id` |
| links | `file_id`, `tenant_id`, `user_id`, `account_id`, `bank_id`, `cutoff_id` |
| movement | `txn_date`, `concept`, `abonos`, `cargos` |
| derived | `amount`, `concept_sk`, `row_hash` |

They are followed by `occurrence`, `entry_source`, `note`, `created_at` and `created_by`.
Every master fact table, debit, credit and asset, stops there with the same columns
(sql/024). `saldos` and `tarjeta` are not stored and are not
returned by GraphQL or Sheets.

* **`file_id`** points at the upload (`statement_uploads_f`; assets: `aaccandass_uploads_f`).
  It is empty for opening and adjustment rows. `file_name` and `source_profile` are not
  columns of any master. `movement_keys_v` reads them from `statement_uploads_f`
  (`original_filename`, `source_profile`; assets: `aaccandass_uploads_f.chosen_filename`,
  and `entry_source` when the row has no statement upload). `account_number`, `bank_name`
  and the period dates come from `bank_accounts_d`, `banks_d` and `cutoff_date_f`. GraphQL,
  Google Sheets and the Dimensions page keep those field names.
* **`cutoff_id`** points at `cutoff_date_f`, the period table. Statement periods have
  `period_source = 'statement'`. A row outside every statement period (an installment due
  after the planned periods, an investment month) points at a `period_source = 'ledger'`
  period, which the Statements page, completeness and the period buttons do not show
  (`statement_cutoffs_v`). Future installments are shown in the period their month has on the
  card's current cutoff day.
* **Signs stay per ledger.** Debit `cargos <= 0` and `abonos >= 0`, and
  **`amount = abonos + cargos`**. Credit `cargos >= 0` and `abonos >= 0`, and
  **`amount = abonos - cargos`** (a purchase is negative; before 018 credit amount was
  `cargos - abonos`). Assets keep both amounts positive, like credit, so
  `amount = abonos - cargos`. Opening and adjustment rows use the same signs.
* **The account type is the only routing source** (`account_type_family`, sql/019).
  Bank credit card uses the three credit masters. Bank debit uses the two debit masters.
  Savings, Investment, Asset and Credit contract use the asset masters: a row in the
  current period (the statement period that contains today, or the calendar month) lands
  in `master_open_aaccandass_f` and replaces that account's open rows; every other date
  appends to `master_closed_aaccandass_f`. `ledger_kind` is kept equal to that family.
  `statement_home.future_total` is still the amount owed (positive).
* **`concept_sk`** is the digits of the trimmed concept. When the concept has no digit, it
  is the letters A-Z, upper-cased with accents folded (`Café` becomes `CAFE`,
  `Ñandú` becomes `NANDU`). Before 018 the letters branch kept the case and the accents
  (`Café`). The digits branch did not change.
* **`row_hash`** keeps the sql/014 rule, `occurrence` included. Debit cargos do not change
  sign, so a hash changes only when `concept_sk` does.
* **`tenant_id`** was already filled and NOT NULL (sql/006). It now has a foreign key with
  `user_id` to `tenant_users`.

## The rebuild keeps every row

Each table is copied into the new layout, the old table is dropped and the copy takes its
name. Each hash change is written to `row_hash_remap_f`, and
`apply_row_hash_remap(batch)` moves the rows that depend on a hash:

* attribute rows (`debit_d`, `credit_d`, `master_closed_aaccandass_d`) and their list items;
* transfer links (`inter_accounts_d`), which get new link hashes;
* `aaccandass_checks_f.adjustment_hash`.

Applying 018 again changes nothing. On a database that already has the 018 layout,
`postgres_ops` skips 006 to 017, because their old column lists no longer fit, and runs 018
in their place.

## Opening balance and monthly check (any account)

* **Saldo inicial**: `add_opening_balance(account, balance, date, concept, note)` or
  `POST /balances/opening`. An account has only one. It must be dated before the first
  movement; the default is the day before it. For a card, the balance is the amount owed and
  is stored as a cargo.
* **Monthly check**: `reconcile_account(account, as_of, reported_balance, ...)` or
  `POST /balances/reconcile`. It compares the balance the bank shows with the stored rows;
  any difference becomes one adjustment row. Every check is kept in `aaccandass_checks_f`.
* **Where these rows live**: in the account's closed table (assets: their own table), with
  `file_id` empty and `entry_source` set to `opening` or `adjustment`. This means:
  * Sheets, GraphQL, Dimensions and the balances see them without a union.
  * Open and future tables are replaced on every upload, so they could not hold these rows.
  * Completeness counts files, so it does not change.
  * Transfer detection skips them.
  * Deleting a file removes only that file's rows.
  * `DELETE /balances/rows/{rowHash}` removes one opening or adjustment row. Uploaded rows
    leave only with their file.
* **Balance**: `account_balance_home` (`GET /balances/{accountId}`). It is the sum of
  `amount` over the closed and open rows (future installments not counted). A card shows it
  as the amount owed. GraphQL `balance` now covers every kind.

## Banks

`GET /banks` lists the banks. `POST /banks` adds one; `POST /banks/{id}` renames one.
`DELETE /banks/{id}` removes one. `POST /accounts/{id}/bank` moves an account to another bank.

* A bank can be renamed only when no other customer has an account there and no built-in
  statement profile reads it (Banorte and BBVA keep their names).
* A bank can be removed only by the person who added it, in that tenant (`banks_d_delete`
  allows `strm_app` to delete only that row). Banorte, BBVA, and any other built-in name
  stay. If any account, of any customer, still uses it, the answer is "Move or delete its
  accounts first".
* Any bank can now hold debit and credit accounts. A bank without a built-in profile reads
  its files with a column map.
* Moving an account re-keys its rows (`row_hash` includes `bank_id`, closed rows too, inside
  `set_account_bank` only). Attributes, list items, transfer links and checks follow it
  (`row_hash_remap_f`, batch `bank:...`).
* Uploads, periods and completeness are keyed by account, so they do not change. Files
  already in the S3 vault keep their names, because the vault is write-once. The next files
  use the new bank name.

## Column map wizard

Every statement upload slot gets the wizard: the closed, open and current periods of debit
and credit accounts. The installment slot keeps its plan parsers. When a file matches no
built-in profile and no saved map of the account, the upload asks to map the columns:

* the date;
* the concept (one or more columns joined);
* the cargo and the abono columns. Using the same column for both means one signed amount:
  positive is an abono, negative is a cargo.

Every other column is ignored.

The map is stored in `aaccandass_templates_d`, the sql/017 table, now used by every account
kind. Its `header_signature` (the sorted normalized headers) lets the next file with the
same header row load without asking. The upload records the map in
`statement_uploads_f.column_map_id` and `source_profile = 'column_map'`. Preview:
`POST /statements/preview` (`column_map_preview`, the generalized `aaccandass_preview`).
Built-in bank profiles run first, as before.

## Apply order

1. `sql/016_lists_completeness_transfers.sql`, `sql/017_investments_assets.sql`
2. `sql/018_standard_masters_balances_banks.sql`
3. After you confirm the list in its header: `sql/018b_drop_unused.sql`. It drops
   `open_debit_f`, `open_credit_f`, `movement_dimensions_d` and `bank_templates_f`.
   `credit_plan_closed_f` stays commented out. Column maps use `aaccandass_templates_d`
   and the upload wizard. The `/admin` Lambda is removed; banks are added on the
   Statements page.
