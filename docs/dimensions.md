# Movement attributes, lists, the Dimensions page and upload completeness (sql/015, sql/016)

> **sql/018:** the Dimensions page shows the original `concept` first and `concept_sk` as a secondary column. `movement_dimensions_d` is no longer written (attribute rows live in `debit_d` / `credit_d`) and `sql/018b_drop_unused.sql` drops it.

sql/017 adds a third group, **Investments & assets** (`master_closed_aaccandass_d`, kind
`asset`). sql/019 adds layer `open` (`master_open_aaccandass_f`); both layers share that
attributes table. See `docs/investments_assets.md`. Asset accounts are not part of upload
completeness.

## Tables

| table      | covers                                              |
|------------|-----------------------------------------------------|
| `debit_d`  | `master_debit_closed_f`, `master_debit_open_f`      |
| `credit_d` | `master_credit_closed_f`, `master_credit_open_f`, `master_credit_future_f` |

Columns: `row_hash` (primary key, the movement key from `docs/row_hash.md`), `tenant_id`,
`user_id`, `account_id`, `attribute_1`, `attribute_2`, `attribute_3` (free text, ≤ 500
characters, blank = NULL), `created_at`, `created_by`, `updated_at`, `updated_by`. Row
level security: tenant and user, like the masters. `strm_app` only reads them; writes go
through `save_dimension`.

- Every stored movement has a row: an `AFTER INSERT` statement trigger on each master
  adds it (empty), and 015 seeds the rows for movements that already exist.
- **Open → closed**: the closed upload stores the same movement with the same
  `row_hash`, so the attribute row (and its labels) simply stays.
- **Re-dated installments** (cutoff change, sql/012/014): the new `row_hash` gets the
  old row's attributes through `public.movement_rekeyed` (a no-op before 015).
- Deleting an upload keeps the attribute rows: uploading the same file again brings
  back the same `row_hash` values and their labels. Deleting the account removes them
  (FK `ON DELETE CASCADE`).

### Why keep `movement_dimensions_d`

`movement_dimensions_d` (006) is a key registry (`tenant_id`, `row_hash`, `user_id`,
`account_id`, `created_at`) with no attribute columns, and the ingest still writes it.
015 keeps it (removing it would mean rewriting the live ingest functions again) and uses
it once: to seed `created_at` of the new rows. Nothing new reads it; it can be dropped in
a later migration once the ingest stops writing it.

## Functions (SECURITY DEFINER, session tenant and user)

- `dimension_summary()` → `{debit: {total, filled, pct, layers: {open, closed}},
  credit: {…, layers: {open, closed, future}}}`; a movement counts as filled when any of
  `attribute_1..3` is set.
- `dimension_rows(kind, layer, from, to, search, limit, offset)` → `{total, rows: [...]}`;
  `search` matches concept, concept_sk, bank, account number and the attributes
  (case-insensitive); `limit` ≤ 500.
- `save_dimension(row_hash, attribute_1, attribute_2, attribute_3)`.

API (Cognito): `GET /dimensions`, `GET /dimensions/rows?kind=&layer=&from=&to=&q=`,
`POST /dimensions` — in `infra/lambda/statements.ts` and `apps/statements/local_api.py`.

## Page

`web/dimensions.js`, opened from the ribbon (**Dimensions**). Two expandable groups —
Debit (Open, Closed) and Credit (Open, Closed, Future) — each with the share of movements
that have attributes. A layer shows a date range and name filter, the rows (account,
bank, date, concept_sk, abonos, cargos, attributes); pick one row, edit the three
attributes, Save.

## Attribute lists (sql/016)

Each of `attribute_1..3` is, per user, either **free text** (as in 015) or **bound to a
list**. Lists are shared by debit and credit.

| table                  | what                                                         |
|------------------------|--------------------------------------------------------------|
| `list_f`               | `list_id`, `tenant_id`, `user_id`, `list_name` (unique per user, case-insensitive) + control columns |
| `list_d`               | `item_id`, `list_id`, `tenant_id`, `user_id`, `item_name` (unique per list, case-insensitive) + control columns |
| `attribute_settings_d` | per user and `slot` 1–3: `label` (shown on the pages) and `list_id` (NULL = free text) |

`debit_d` / `credit_d` get `attribute_1_item_id … attribute_3_item_id` (FK `list_d`). A
list-bound value is stored as the **item id** (the text column is NULL), so renaming an
item renames it on every movement, on the pages and in Google Sheets.
`movement_attributes_v` resolves the values (`item_name` for list-bound, else text); every
reader (`dimension_summary`, `dimension_rows`, `graphql_rows`) uses it, so the API always
returns the item **name**. RLS: tenant and user on all three tables; `strm_app` only reads,
writes go through the functions.

Switching a slot:

- **free text → list**: every value already typed in that slot becomes an item of the list
  (created when missing, case-insensitive, spaces collapsed) and is stored as its id.
- **list → free text**: the item names are written back as text.
- **list A → list B**: values are moved by name into list B.

No value is lost either way. Items cannot be deleted yet (only renamed), so nothing can
point at a missing item.

Functions: `list_catalog()` (lists with items and how many movements use each item, and the
three slots), `create_list(name)`, `rename_list(list_id, name)`,
`add_list_item(list_id, name)` (returns the existing item when the name is taken),
`rename_list_item(item_id, name)`, `set_attribute_setting(slot, label, list_id)`,
`save_dimension_values(row_hash, values)` — `values` keys `attribute_1..3`, each one of:
absent (keep), `null`/`""` (clear), `"text"` (free text; on a list slot the item with that
name, created when missing), `{"item_id": n}` (list slot only), `{"new_item": "x"}` (the
inline "create new item"). `save_dimension(row_hash, a1, a2, a3)` from 015 still works on
both kinds of slot. Limits: 50 lists per user, 1000 items per list, names ≤ 100 (list) and
≤ 500 (item) characters.

API: `GET /lists`, `POST /lists {list_name}`, `POST /lists/{id} {list_name}`,
`POST /lists/{id}/items {item_name}`, `POST /list-items/{id} {item_name}`,
`POST /attribute-settings {slot, label, list_id}`, and `POST /dimensions {row_hash, values}`.

Pages: **Lists** (ribbon) — the three slots (label, Free text or a list), create/rename
lists, add/rename items. **Dimensions** row editor — a list-bound attribute is a picker of
the list's items plus "+ New item…", free-text attributes stay text boxes; the table
headers use the labels. Each row also shows its transfer link (`docs/transfers.md`), and
the editor can link, keep or unlink it.

## Upload completeness (sql/016)

On the Statements (uploads) page, above the accounts: Credit / Debit › bank › account,
each with a percentage and colour, expandable like the Dimensions page.
`public.upload_completeness(as_of)` computes it; `GET /statements` returns it as
`completeness` (same day as the home).

**Target per account**: the current (open) period as of today plus the **two closed
periods before it** — three periods.

**Score per period**

| period | uploads                                         | plan with PDF backup | plan without PDF |
|--------|-------------------------------------------------|----------------------|------------------|
| open   | CSV                                             | 100                  | 100              |
| open   | nothing                                         | 0                    | 0                |
| closed | closed-statement CSV + PDF ("certified")        | 100                  | —                |
| closed | closed-statement CSV                            | 75                   | 100              |
| closed | only the open-period snapshot CSV (+ PDF)       | 40 (65)              | 50               |
| closed | PDF only                                        | 25                   | —                |
| closed | nothing, or the period is not stored            | 0                    | 0                |

The PDF counts only on plans that keep it (`plans_d.curated_csv_backup`, Premium today);
elsewhere a closed CSV is already complete. Installment (MSI) files are not part of the
score.

**Roll-up**: account % = average of its three period scores; bank % = average of its
accounts; Credit/Debit % = average of their accounts; overall % = average of all accounts.

**Colour bands** (`completeness_band`): `complete` = 100 (full green), `filled` ≥ 75
(green), `partial` ≥ 50, `low` > 0, `empty` = 0 (grey). The page colour is continuous:
0 % grey; above 0 the hue goes from red (just above 0) through amber to green and gets
stronger with the score; 100 % is full green. Each period line says what is missing
("Upload the statement CSV", "Add the PDF to certify it", …).
