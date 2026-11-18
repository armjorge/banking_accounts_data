# Movement key (`row_hash`) and sign convention

> **sql/018:** debit `cargos` stay `<= 0` and credit `cargos` stay `>= 0`. Debit `amount = abonos + cargos`. Credit and asset `amount = abonos - cargos` (a card purchase is negative; before 018 credit amount was `cargos - abonos`). `concept_sk` letters are upper-cased with accents folded. The hash inputs below are unchanged; rows whose `concept_sk` changed were re-keyed through `row_hash_remap_f` (see `docs/standard_masters.md`).

Applies to the five movement masters from `sql/014_normalized_row_hash.sql` on:

| Table | Layer | Kind |
| --- | --- | --- |
| `master_debit_closed_f` | closed | debit |
| `master_debit_open_f` | open | debit |
| `master_credit_closed_f` | closed | credit |
| `master_credit_open_f` | open | credit |
| `master_credit_future_f` | future | credit (card installments; same schema as the credit tables; `master_debit_future_f` before 014) |

All five have the same amount columns, `abonos` and `cargos`. Before 014 the credit
tables and the future table called them `abono` and `cargo`.

## Signs

| Kind | `cargos` | `abonos` | `amount` |
| --- | --- | --- | --- |
| Debit (bank account) | money out, stored `<= 0` | money in, stored `>= 0` | `abonos + cargos` |
| Credit card (closed, open, future) | charge, stored `>= 0` | payment or refund, stored `>= 0` | `abonos - cargos` |
| Asset (`master_closed_aaccandass_f`, `master_open_aaccandass_f`) | money out or loss, stored `>= 0` | money in or gain, stored `>= 0` | `abonos - cargos` |

Each table enforces this with a `<table>_sign_check` CHECK constraint (014). If a table
already had rows that broke the rule, 014 would add the CHECK as `NOT VALID` and raise a
NOTICE with the count instead of changing data. Live data had no such rows on
2026-11-12, so all five CHECKs are fully validated.

### Worked example: paying the card

You pay 1,500.00 to the Banorte card (account 12) from the payroll account (account 4)
on 2026-11-05.

| Table | account | `cargos` | `abonos` | `amount` |
| --- | --- | --- | --- | --- |
| `master_debit_closed_f` (payroll) | 4 | `-1500.00` | `0.00` | `-1500.00` |
| `master_credit_closed_f` (card) | 12 | `0.00` | `1500.00` | `1500.00` |

The bank account goes down by 1,500.00. On the card, `amount = abonos - cargos` is
+1,500.00, and the amount owed is the negation of that sum, so the debt goes down by
1,500.00. The debit `cargos` (-1500.00) and the credit `abonos` (+1500.00) are the two
legs of the same payment. They have different keys, because account, concept and amounts
differ.

## Key inputs and format

```
row_hash = sha256_hex( user_id | account_id | bank_id | txn_date | concept_sk | abonos | cargos | occurrence )
```

`public.movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos,
cargos, occurrence)` builds it. The Python mirror is
`apps/statements/rules.py: movement_row_hash_v2`.

| Input | Format |
| --- | --- |
| `user_id` | uuid as text, lowercase with hyphens |
| `account_id` | integer as text (`bank_accounts_d.account_id`) |
| `bank_id` | integer as text (`banks_d.bank_id` of the account; new column in 014) |
| `txn_date` | `YYYY-MM-DD` |
| `concept_sk` | as stored (digits of the concept, or its letters when it has no digits) |
| `abonos`, `cargos` | the stored signed values. Two decimals, `-` only for negatives, no thousands separator, never `-0.00` (`public.movement_amount_text`). Rounding is half away from zero. |
| `occurrence` | integer as text, from 1 |

Separator `|`. Text is UTF-8. Output is 64 lowercase hex characters.

Example: user `8f14e45f-ceea-467a-9f2b-0123456789ab`, account 7, bank 1, a SPEI of 250.00
out of a debit account on 2026-11-03 whose concept key is `4411`:

```
8f14e45f-ceea-467a-9f2b-0123456789ab|7|1|2026-11-03|4411|0.00|-250.00|1
-> aed6d5ed8bbc62511908be3f23a2c583b6e2ab0c33a8f4995adea7532918500d
```

A second identical SPEI in the same file gets `occurrence` 2:

```
...|4411|0.00|-250.00|2  -> 707bf2a30db79574d0c5368e1ee17864ac0042d7525024999b6e6c8226b521a5
```

### Why `user_id` (not tenant)

Every master carries both `tenant_id` and `user_id`. Row level security requires both to
match the session. `bank_accounts_d` is keyed by `(account_id, user_id)`. The uploader is
always the account owner, because the ingest only loads into accounts of the session user.
So `user_id` is the owner key. The tenant is implied by the account and is not hashed.

### Occurrence (decision to confirm)

`occurrence` is not in the list Jorge gave. It is kept as the last input. Without it, two
genuinely identical movements (same account, day, concept and amounts, e.g. two 20.00
Microsoft charges on the same day) would get the same key. The second would then be
rejected as "already uploaded" (closed) or violate the unique index (open and future).

The ingest numbers rows within one upload, ordered by file row, partitioned by
`(txn_date, concept_sk, abonos, cargos)`, which are exactly the other inputs. On
2026-11-12 the stored occurrence of every live row already matched this rule, so the
migration keeps the stored values.

### Not in the key

* **Running balance and card name**: debit files carry a `saldos` column and credit files
  a `tarjeta` column. Neither is stored on the master (sql/018). The same movement can
  show a different running balance in another file, and the card name is not part of the
  movement.
* **Period (`period_start`/`period_end`)**: a movement read from the open book and later
  from the closed statement must keep its key. A cutoff-day change re-plans periods.
* **File (`file_id`, `file_name`)**: re-uploading or replacing a file must not change the
  key. `file_name` is read from `statement_uploads_f` through `file_id`.
* **Names (`bank_name`, `account_number`, `concept`)**: the ids identify the account.
  `concept_sk` is the stable part of the concept.
* **`amount`**: it is derived from `abonos` and `cargos`.

## Behaviour

* **Open to closed.** The current-period (open) row and the same movement in the closed
  statement get the same key, so dimensions keyed by `row_hash` carry over. On
  2026-11-12, 8 live movements (Oct 31 – Nov 2) are in both the open and the closed book
  of the same account with the same key. `movement_keys_v` lists them once per layer.
* **Closed uploads** are append-only. A file whose key is already stored for the account
  is rejected as "already uploaded".
* **Installments (future).** Each remaining payment is its own row dated on its due date,
  so the date is in the key. When a card's cutoff day changes (`sql/012`), Banorte-style
  payments are re-dated and get new keys. BBVA purchase-day payments keep their date and
  key. A future row does not share a key with the real charge in a later statement,
  because the date and concept differ.
* **`movement_dimensions_d`** holds one row per `(tenant_id, row_hash)`. 014 moves each
  dimension row to its movement's new key and keeps `created_at`. Old-format dimension
  rows that no stored movement maps to are left unchanged (24 such rows live on
  2026-11-12, left behind by files replaced or deleted before 014).

## Soft key view

`public.movement_keys_v` has one row per stored movement in the five masters, with these
columns:

* `row_hash`, `layer` (closed, open, future), `kind` (debit, credit), `source_table`;
* `row_id`, `file_id`, `tenant_id`, `user_id`, `account_id`, `bank_id`;
* `txn_date`, `concept_sk`, `abonos`, `cargos`, `amount`, `occurrence`.

It runs with `security_invoker`, so each master's row level security applies to the
caller.
