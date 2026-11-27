# Design

## Context

See proposal.md for why. Movements store `attribute_1` through `attribute_3` and matching `attribute_N_item_id` columns on `debit_d`, `credit_d`, and `master_closed_aaccandass_d`. `attribute_settings_d` binds each of those three slots to any list. `sql/026_nested_lists.sql` adds `parent_list_id` and `parent_item_id`, and the dimension editor can store a sub-item id on the parent attribute when the next slot is a different list. The Lists page and the editor live in `web/dimensions.js`.

## Goals / Non-Goals

**Goals:**

- Five stored attributes with fixed roles, shared by debit, credit, and asset rows.
- A catalog cap of two root lists and one nested list each, enforced in the database as well as the page.
- One migration that places existing item ids and free text on the slot that matches the new role.

**Non-Goals:**

- A third root list, a second nested list on one root, or a third nesting level.
- Letting the person bind a slot to a list of their choice.
- Changing GraphQL quota or the ledger tables inside `encrypted-ledger-duckdb`. That change must read five attributes when it is applied.

## Decisions

### The two root lists are the two oldest

List 1 is the person's oldest root list. List 2 is the next oldest. Each sublist slot uses the nested list whose `parent_list_id` is that root list, when one exists. Creation order is the assignment, so the page no longer asks which list a slot uses.

Alternative: keep `attribute_settings_d.list_id` as the assignment. Rejected because that is the binding model this change removes. The settings rows remain only for the five labels.

### Store the pair on two columns

`attribute_1_item_id` is list 1's root item. `attribute_2_item_id` is the sub-item of that item. `attribute_3_item_id` is list 2's root item. `attribute_4_item_id` is the sub-item of that item. `attribute_5` is text and has no item id. Add `attribute_4`, `attribute_4_item_id`, and `attribute_5` on the three dimension tables. The save path rejects a sub-item whose parent is not the selected root item, and it rejects a sub-item id written into a list slot.

Alternative: keep storing the sub-item on the parent attribute and show both names in one cell. Rejected because the person asked for five separate fields.

### The editor is five controls, not a bound catalog

The dimension editor always renders the five roles. A sublist select lists only children of the selected parent item, and it is empty when that item is empty. "+ New item" on a sublist creates the item under the selected parent. The Lists page stops offering "bind this slot to a list." It still renames labels, root items, the nested list, and sub-items, and it refuses a third root list.

## Risks / Trade-offs

- [A movement that stored People on attribute 2 now shows that value on list 2] → The migration moves a root item of the second list from attribute 2 to attribute 3 before the page is published.
- [A sub-item id stored on attribute 1 would otherwise display as the list value] → The migration copies it to attribute 2 and sets attribute 1 to that sub-item's parent item.
- [More than two root lists already exist] → The two oldest stay active. The others remain stored and are hidden. Creating another root list fails until one active root list is deleted.
- [Readers that still select three attributes] → Extend the statement grid, the assets summary, and any export that prints `attribute_1` through `attribute_3` so they print five. Do not invent a second copy of the values.

## Migration Plan

Apply one SQL file after `sql/026_nested_lists.sql`. It adds the new columns, moves existing values as above, and replaces the save and catalog functions. Then publish `web/dimensions.js`. Rollback is the previous page and the previous save function. The new columns can stay. A data rollback is not automatic: the move is one-way, so take it only after the mapping above is checked on a copy of the dev database.

## Open Questions

None. Slot order, the two-list cap, and optional list values are fixed by the proposal.
