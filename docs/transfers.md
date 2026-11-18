# Transfers between your accounts (sql/016)

Money that moves between two of your own accounts is not income or spending. A transfer
link ties the two movements together so the sheet (and later reports) can leave them out.

## Table `inter_accounts_d`

| column | meaning |
|--------|---------|
| `link_hash` (PK) | SHA-256 hex of `sending_hash || ':' || receiving_hash` |
| `sending_hash` | `row_hash` of the money-out side: a **debit** movement with `abonos + cargos < 0` |
| `receiving_hash` | `row_hash` of the money-in side: a **debit** movement with `abonos + cargos > 0`, or a **credit** movement with `abonos > 0` (a card payment from a debit account is a transfer) |
| `sending_account_id`, `receiving_account_id`, `receiving_kind` | the two accounts (always different) and `debit`/`credit` |
| `transfer_type` | `same_bank` or `inter_bank` |
| `source` | `auto` (detection) or `manual` (you linked it) |
| `status` | `active` or `unlinked` (kept so a pair you unlinked is never proposed again) |
| `txn_date`, `receiving_date`, `amount`, `amount_difference` | from the two movements (manual links may differ in date or amount) |
| `match_candidates` | auto links: how many money-in movements matched; more than 1 = check it |
| `reviewed_at`, `reviewed_by` | set when you keep (confirm) or make a link; NULL = auto link to review |
| `tenant_id`, `user_id`, `created_*`, `updated_*` | owner and control columns; RLS by tenant and user |

A movement is in at most one active link (unique partial indexes). Links use `row_hash`,
so a movement keeps its link when its period closes (same `row_hash` in the closed book).
Credit-card installment rows (future layer) cannot be linked.

## Detection rule

Based on the debit query Jorge uses (`same_bank_flag` / `cross_bank_flag`), extended to
card payments:

1. Candidates: open and closed movements; a movement in both books counts once.
2. A sending movement and a receiving movement of **two different accounts** with the
   **same `txn_date`** and the **same absolute amount**.
3. **Pass 1 — same bank**, then **pass 2 — across banks** with what is left.
4. Senders are taken in (date, amount, account, row) order; each takes the first free
   receiver (debit before credit, then account, then row). Each movement is used once.
5. A pair you unlinked is skipped.

Difference from the original query: that query pairs by `row_id` inside a bank and can
pair two rows of the **same account** (for example a charge and an unrelated deposit of the
same amount on the same day). 016 requires two different accounts. On a copy of the live
data both find 64 debit-closed rows; 3 pairs differ, all on HSBC 4598/4622, and in each
case 016 picks the row whose concept names the other account ("TRANSFERENCIA A - 4598"),
where the old query had paired two rows inside 4598.

## Automatic links (default) and suggestions

- `dimension_settings_d.auto_link_transfers` (default **true**): matches are **created**
  with `source = 'auto'` and `reviewed_at` NULL, so the page shows them "to review".
  Detection runs when 016 is applied, after every upload (statement trigger on the four
  open/closed masters; a failure only logs a warning, the upload is never blocked) and on
  **Find transfers now**.
- Auto links that nobody reviewed and whose movement is gone (an open-period file was
  replaced) are removed on the next detection; kept or manual links stay and show the
  missing side.
- With the switch off, matches are only **suggested** (`transfer_links().suggestions`)
  and you link them with one click.

## Functions and API (session tenant and user)

| function | API |
|----------|-----|
| `transfer_links()` → `{auto_link_transfers, links, suggestions}` | `GET /transfers` |
| `link_transfer(row_a, row_b)` — any two movements, either order; the money-out debit row becomes the sending side | `POST /transfers {row_a, row_b}` |
| `unlink_transfer(link_hash)` | `DELETE /transfers/{link_hash}` |
| `confirm_transfer(link_hash)` — keep an auto link | `POST /transfers/{link_hash}/confirm` |
| `detect_transfers(create)` — NULL = the setting | `POST /transfers/detect {create?}` |
| `set_transfer_auto(enabled)` | `POST /transfers/settings {auto_link_transfers}` |
| `transfer_partners(row_hash, search, limit)` — opposite side, another account, not linked; same amount first, then nearest date (±45 days without a search) | `GET /transfers/partners?row_hash=&q=` |

Readers: `dimension_rows` and `graphql_rows` return `is_internal_transfer`,
`transfer_link_hash`, `transfer_role`, `transfer_type`, `transfer_source`,
`transfer_counterpart_account` on every row; `dimension_summary` counts `transfers` per
kind and layer. GraphQL: the same fields plus `excludeTransfers: true` (`docs/graphql.md`).

## Page

Dimensions › **Transfers between your accounts**: the switch, **Find transfers now**, the
active links (auto ones to review first, with **Keep** / **Unlink**) and suggestions. In a
Debit/Credit layer each row shows `↔ → 1122` (or `←`) when linked; the row editor can keep
or unlink it, or **Link as transfer…** to pick the other side from `transfer_partners`.

## Tests

`apps/statements/tests/test_lists_transfers_completeness.py`: same-bank, card-payment and
inter-bank auto links; flags on rows; unlink remembered; manual link in either order;
already-linked and same-side errors; suggestions with auto off; auto links of replaced
open rows dropped; GraphQL flag and `excludeTransfers`; RLS.
