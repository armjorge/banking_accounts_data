# Roadmap: user templates, reconciliation, tags, investments and assets

Status: design only (no SQL or code yet). Written 2026-11-13 on top of 016.
Each part lists tables, page flows and open questions. Phases and Jira epics are at the end.

Conventions used below (same as today):

- Debit: `abonos` positive (money in), `cargos` negative (money out), `amount = abonos + cargos`.
- Credit: both columns positive. `cargos` = purchases (debt goes up), `abonos` = payments (debt goes down).
- Every new table carries `tenant_id`, `user_id`, RLS `TO strm_app`, and is written only through
  `SECURITY DEFINER` functions that call `require_session()`.
- New rows that behave like movements get a `row_hash` and appear in `movement_keys_v`, so
  dimensions (015), lists (016), transfers (016) and GraphQL work on them with no extra code.

---

## 1. User upload templates (per bank + account)

### Today

- `file_profiles_d` (007) holds global, preloaded profiles: `header_signature`, `column_map`,
  `amount_rule`, date and number formats.
- `ingest_statement_csv` (latest in 011) finds the profile by bank name + dataset + exact header
  signature, then by the alias rule (fecha + cargo(s) + abono(s)), then headerless detection.
- `bank_templates_f` (004) was an older admin table (bank + account type → header text). sql/018b drops it. Column maps live in `aaccandass_templates_d`.
- Python `build_user_profile()` already builds a profile from a column map, but nothing stores it.

### Proposal

A user template is a profile owned by one user and tied to one account (the upload slot).
The slot already gives `bank_id`, `account_id` and debit/credit, so the file only needs to provide:

| Field | Required | Notes |
|---|---|---|
| txn_date | yes | user picks the date format (DD/MM/YYYY, YYYY-MM-DD, DD-MMM-YY…) |
| abono | yes* | money in (debit) / payment (credit) |
| cargo | yes* | money out (debit) / purchase (credit) |
| amount | alt. | one signed column instead of abono + cargo (`single_signed`) |
| description | no | empty → `"(sin descripción)"` so `concept_sk` and `row_hash` still work |
| balance | no | debit only; used by reconciliation (part 2) when present |

\* Either abono + cargo, or one signed amount column.

Sign rules applied by the template (the user doesn't have to clean the file):

- Debit: abono stored as `ABS(x)`, cargo stored as `-ABS(x)`. With a single amount column, the sign is kept,
  with an option "my bank shows charges as positive" that flips it.
- Credit: both stored as `ABS(x)`. With a single amount column, the user says which sign means purchase.

Tables:

```
user_file_profiles_d
  profile_id BIGINT identity PK
  tenant_id, user_id
  account_id INTEGER  -- FK bank_accounts_d (account_id, user_id); one active per account
  dataset TEXT        -- 'debit' | 'credit_monthly' (never 'credit_plan')
  header_row INTEGER DEFAULT 1   -- rows above it are skipped (preambles)
  column_map JSONB    -- {"txn_date": "Fecha Op", "abono": "Depósitos", "cargo": "Retiros",
                      --  "description": "Concepto", "balance": "Saldo"}  (normalized header text)
  header_signature TEXT[]  -- sorted normalize_header() of the mapped headers, for detection
  amount_rule TEXT    -- reuse: split_signed | split_positive_credit | single_signed
  charges_positive BOOLEAN DEFAULT TRUE  -- only for single_signed
  date_format, decimal_sep, thousands_sep
  skip_rows_matching TEXT  -- optional: "Total", "Saldo anterior"… (like is_statement_skip_row)
  active BOOLEAN, created_at, updated_at
```

Ingest change (one place): in `ingest_statement_csv`, before the global lookup, check the account's
active `user_file_profiles_d` row. If its signature matches, use it. If not, fall back to today's
global profiles. The parsed rows are inserted into the same masters (`open_*`, `master_*_closed_f`),
with the same `row_hash`. So everything downstream stays the same.

Installments (`credit_plan`) stay as preloaded profiles only (formats are bank-specific with
`pagos N de M` logic). For banks we don't support, we offer **our own installment format**,
a CSV the user fills in:

```
fecha_compra, descripcion, monto_original, mensualidad, pagos_hechos, pagos_totales, interes
```

This maps 1:1 to an internal `bsf_installment_v1` global profile, so no user mapping is needed.

### Page flow: "Upload format" (from the account's upload slot)

1. The user uploads a sample file → the browser reads it (CSV/XLSX like today) and shows the first 10 rows.
2. The user picks the header row, then assigns each required field from a dropdown of the file's headers.
3. The user picks the date format and sign options. A live preview shows 5 parsed rows with the final signs.
4. Save → template stored. A "Use this file now" option ingests the sample right away.
5. Later uploads to that slot go straight through. A failed match says "Headers changed. Edit format?"

### Open questions

- Can a template be shared with other users of the same bank (admin promotes it to `file_profiles_d`)?
- Allow more than one template per account (e.g. bank changed its export format)? Proposal: yes, all active ones are tried.
- Headerless files (HSBC style, mapping by column number): include in phase 1 or later?

---

## 2. Reconciliation rows and balance at any date

### Goal

For every account, the balance on any date is known and matches the PDF/statement.

### Model

```
balance_at(D) = opening_balance + Σ movements (txn_date ≤ D) + Σ adjustments (adj_date ≤ D)
```

Accounts start at 0 unless the user sets an opening balance. Any month, the user can add a
dated adjustment so the computed balance equals the statement balance.

```
account_balance_points_d        -- what the statement/PDF says (user input or read from saldos)
  point_id identity, tenant_id, user_id, account_id
  as_of DATE, statement_balance NUMERIC(18,2)
  source TEXT  -- 'manual' | 'csv_saldos' | 'pdf' (pdf = user typed it while viewing the PDF)
  upload_id UUID NULL  -- link to the PDF/CSV upload it came from
  unique (account_id, as_of)

account_adjustments_f           -- the reconciliation rows
  adjustment_id identity, tenant_id, user_id, account_id
  adj_date DATE, amount NUMERIC(18,2)  -- signed like debit; credit: + = more debt
  kind TEXT  -- 'opening' | 'reconcile' | 'gross_income' | 'gross_outcome'
  note TEXT, point_id NULL   -- which balance point it closes
  row_hash TEXT  -- 'adj:' scope so it never collides with bank rows
  created_at
```

Function `reconcile_account(account_id, as_of, statement_balance)`:
- computes `balance_at(as_of)`, stores the point, and if the difference is ≠ 0 creates one
  `reconcile` adjustment for the difference (or updates the one already tied to that point).
  It never changes bank rows.

View `account_balance_v (account_id, as_of, computed, statement, difference, status)`, with status
`matched` | `adjusted` | `unchecked`.

Debit CSVs already carry `saldos`, so the last row of each closed period can create a `csv_saldos` point
automatically. Then a debit account with full CSVs reconciles with no typing.

### Dummy gross CSV (no bank CSV available)

When a period has only a PDF (or nothing), the user enters two numbers from the PDF summary:
total deposits and total withdrawals (credit: purchases and payments). We store them as two
adjustment rows, `gross_income` and `gross_outcome`, dated on `period_end`, plus the closing balance point.
For completeness (016) this counts as "CSV present" but with a lower score (proposal: 50, PDF still +25)
and the badge says "summary only".

### Page flows

- **Balances page** (new, per account): a monthly table with computed balance, statement balance, difference and a status pill.
  - "Set opening balance" on the first row.
  - "Reconcile" on any month: type the PDF balance, see the difference, confirm → adjustment row.
  - "Enter totals (no CSV)" on months with no CSV: income total, outcome total, closing balance.
- Adjustments show in Dimensions as rows with a grey "Adjustment" badge, so they can be tagged like any row.

### Open questions

- Credit accounts: should the balance be "debt owed" (positive) or a negative number? Proposal: debt as positive, shown in red.
- Should a later real CSV for a "summary only" month delete the dummy gross rows automatically? Proposal: yes, with a warning.
- Do adjustments go to GraphQL by default? Proposal: yes, with `kind` so Sheets can filter them.

---

## 3. Tags (#words)

### Proposal

A fourth kind of attribute: free `#tags`, any number per row, separate from the 3 slots.
Lists (016) = one controlled value per slot ("Category: Rent"). Tags = many loose labels
("#vacaciones2026 #reembolsable #mamá").

```
tag_d          tag_id identity, tenant_id, user_id, tag_name (lowercase, no '#', 1–40, [a-z0-9_áéíóúñü-])
               unique (tenant_id, user_id, tag_name)
movement_tags_f  tenant_id, user_id, row_hash, layer ('debit'|'credit'), tag_id
               PK (user_id, row_hash, tag_id)
```

- Typing in a row's description/note field: any `#word` is turned into a tag on save. A tag chip input is also available.
- Rename/merge a tag changes it everywhere (rows store `tag_id`, same as list items).
- On replace/re-key (`movement_rekeyed`), tags move with the row, like 015 dimensions.
- View: tags show as coloured chips. A `#word` in the concept text is highlighted. Clicking a chip filters the table.
- GraphQL: `tags: [String!]!` on rows plus a `tag: String` filter argument. Sheets: a `tags` column (comma-joined).
- Lists page gets a "Tags" tab: counts, rename, merge, delete (deleting a tag removes it from rows; allowed, unlike list items).

Relation to 016: tags reuse the same rules (per user, RLS, rename by id) but don't use the slots.
Option: a "Promote tag to list item" action (moves a tag into a chosen list and sets the slot on those rows).

### Open questions

- Should `#words` already inside bank concepts (rare) auto-tag? Proposal: no, only user text.
- Limit per row? Proposal: 10.

---

## 4. Investments and assets

### Idea

Same shape as a bank account, but the "movements" are value changes:
`bank (institution) | account | period | concept | abono (gain) | cargo (loss)`.
`initial value + Σ changes up to D = value at D`, the same formula as part 2.

Examples: Infonavit, Afore, CETES, GBM, cash, car, house, other sellable things.

```
asset_accounts_d
  asset_id identity, tenant_id, user_id
  asset_class TEXT  -- 'retirement' (Afore) | 'housing_fund' (Infonavit) | 'fixed_income' (CETES)
                    -- | 'brokerage' (GBM) | 'cash' | 'vehicle' | 'property' | 'other'
  institution TEXT or bank_id NULL (FK banks_d when it is a bank)
  name TEXT, currency TEXT DEFAULT 'MXN'
  initial_value NUMERIC(18,2), initial_date DATE
  expected_annual_rate NUMERIC(7,4) NULL  -- +0.10 = +10%/yr appreciation, -0.15 = depreciation
  valuation_mode TEXT -- 'movements' | 'statements' | 'manual' | 'projected'
  active, created_at

asset_movements_f
  movement_id identity, tenant_id, user_id, asset_id
  txn_date DATE, period_start, period_end
  concept TEXT
  abono NUMERIC(18,2) >= 0   -- gain / contribution
  cargo NUMERIC(18,2) <= 0   -- loss / withdrawal / depreciation
  kind TEXT -- 'contribution' | 'withdrawal' | 'yield' | 'fee' | 'revaluation' | 'projected' | 'reconcile'
  source TEXT -- 'csv' | 'statement' | 'manual' | 'projection'
  upload_id UUID NULL  -- CSV or PDF receipt it came from
  row_hash TEXT        -- 'asset:' scope
```

Three ways to feed values (the user picks per asset, and can mix them):

1. **Upload movements**: a CSV through a user template (part 1, dataset `asset`). For example GBM or CETES exports.
2. **Period statement / PDF receipt**: the user types the closing value from the PDF (Afore/Infonavit statements are
   every 4 months or yearly). The PDF is stored like 006 backups. The difference to the computed value
   becomes one `revaluation` row. This is the same `reconcile_account` logic, reused.
3. **Manual monthly gain/loss**: a quick grid, one row per month, with an amount field.

**Projected** (car, property, cash under rate): a monthly job writes `projected` rows from
`expected_annual_rate`: `value × ((1+rate)^(1/12) − 1)`. Projected rows are replaced when a real valuation
arrives (e.g. a car appraisal). Cash is just `manual` with rate 0.

Transfers (016): a debit row "Aportación voluntaria Afore" or "Compra CETES" can be linked to an
asset contribution. Extend `inter_accounts_d` with `receiving_layer = 'asset'` so it doesn't count as spending.

### Page flow: "Assets" page

- A summary card per asset: current value, change this year, % vs expected, last valuation date (stale > 6 months = amber).
- Total net worth = Σ bank balances (part 2) + Σ assets − credit debt.
- An asset detail page has a value-over-time line, the movement table, and buttons for Upload CSV / Add statement value / Add month / Edit rate.
- "New asset" wizard: class → institution/name → initial value + date → how to keep it updated.

### Open questions

- Currencies: GBM may hold USD. Store per-asset currency only, or convert to MXN with a daily rate?
- Infonavit/Afore: one asset each, or split sub-accounts (RCV, vivienda, voluntary)?
- Should projections run monthly as stored rows, or be calculated on the fly (no rows)? Proposal: on the fly
  for the chart, stored only when the user "closes" a month.
- Does net worth go into GraphQL/Sheets in phase 1?

---

## Phases (suggested order)

| Phase | Scope | Why first | Depends on |
|---|---|---|---|
| A | Tags (part 3) | small, uses 016 patterns, useful right away | 016 |
| B | Balances + reconciliation (part 2), auto `csv_saldos` points | makes balances trustworthy; reused by assets | 016 |
| C | User upload templates (part 1) + our installment format | opens other banks; also feeds assets CSVs | B (balance column) |
| D | Dummy gross totals + completeness "summary only" score | small add-on to B and 016 completeness | B |
| E | Assets: accounts, manual + statement valuation, projections | builds on B's reconcile logic | B |
| F | Asset CSV via templates, transfer links to assets, net worth | joins C, E, 016 transfers | C, E |

Each phase = one forward-only SQL file (017, 018…) with tests, docs, UI, GraphQL fields, same as 015/016.

## Jira epic mapping (suggestion only, nothing created)

| Epic | Phases | Example stories |
|---|---|---|
| Tags | A | tag tables + RLS; #word parse on save; chips + filter in Dimensions; GraphQL `tags`; Tags tab (rename/merge) |
| Balances & Reconciliation | B, D | balance view; opening balance; reconcile flow; auto points from saldos; gross totals; completeness score |
| User Upload Templates | C | template table; ingest lookup; mapping wizard with preview; sign options; BSF installment format |
| Investments & Assets | E, F | asset tables; Assets page; statement/PDF valuation; manual grid; projection; CSV via templates; transfer to asset; net worth |

## Decisions Jorge needs to make

1. Phase order (proposal: A → B → C → D → E → F).
2. Credit balance sign (debt positive?).
3. Completeness score for "summary only" months (proposal 50).
4. Multiple templates per account, and promote-to-global by admin?
5. Tags: limit 10 per row; deleting allowed (unlike list items)?
6. Assets: currency handling, Afore/Infonavit sub-accounts, stored vs on-the-fly projections.
7. Which plan tiers get templates and assets (plans_d limits like accounts today)?
