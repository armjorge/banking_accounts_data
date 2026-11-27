# Design

## Context

See proposal.md for why. `list_f.list_id` is a user's list and `list_d.item_id` is an item of that list (`sql/016_lists_completeness_transfers.sql`). `attribute_settings_d` binds slots 1–3 to a `list_id` or leaves them free text. Movements store `attribute_N_item_id` on `debit_d`, `credit_d`, and `master_closed_aaccandass_d`. The Lists page and the movement editor are in `web/dimensions.js`. Readers show `list_d.item_name` for those ids, so a rename already updates every movement.

## Goals / Non-Goals

**Goals:**

- One nested list per root list, and sub-items that point at a parent `item_id`.
- Attribute choices and saves that follow that link on debit, credit, and asset rows.

**Non-Goals:**

- A third level of lists.
- More than one nested list on the same root list.
- Changing GraphQL quota or the ledger tables in `encrypted-ledger-duckdb`.

## Decisions

### Link the nested list and each sub-item with the existing ids

Add `parent_list_id` on `list_f`, null for a root list, and `parent_item_id` on `list_d`, null for a root item. A nested list's `parent_list_id` is the root list's `list_id`. Each of its items stores `parent_item_id` equal to a `list_d.item_id` of that root list. Uniqueness of the sub-item name is `(list_id, parent_item_id, lower(item_name))`. Root items keep the current per-list name uniqueness.

Alternative: a separate sub-item table with new ids. Rejected because the request is to keep using `list_id` and `item_id`.

### The movement editor filters by the previous slot

The attribute select for a nested slot loads only items with that `parent_item_id`. Changing the previous slot clears the child select before save. The save function checks the same parent link for debit, credit, and asset rows and leaves the stored ids unchanged when the check fails. "+ New item" on a nested slot inserts a `list_d` row under the selected parent item.

The Lists page shows the nested list inside the root list card, and under each root item shows that item's sub-items with add and rename. The attribute binding dropdown labels a nested list as the sublist of its parent list name.

## Risks / Trade-offs

- [A movement keeps a child item after the parent item is renamed] → The link is `item_id`, so the rename stays consistent and the child remains valid.
- [Asset rows and statement rows drift] → One check in the shared attribute save path covers `debit_d`, `credit_d`, and `master_closed_aaccandass_d`.
- [Existing clients omit `parent_item_id`] → Null means a root item. Current lists need no rewrite.

## Migration Plan

Ship the SQL columns and the save check before the Lists page. Old pages keep working because root lists have a null parent. Rollback is the previous API and page; new nested rows can remain unused until the page returns.

## Open Questions

None. One level, one nested list per root list, and the existing ids are fixed by the proposal.
