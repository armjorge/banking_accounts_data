# Proposal

## Why

Lists are flat. A person can bind attribute 1 to a list such as Recurring, but attribute 2 cannot be limited to the sub-items of the Recurring item they just chose. The Lists page needs one level of nesting, using the ids the product already has.

## What Changes

- On the Lists page, a root list (`list_f.list_id`) can have one nested list, also a `list_f` row. Items stay `list_d.item_id`. Each nested item records the parent item it belongs to.
- Under each parent item, the person can add and rename one or more sub-items. Renaming still changes the name everywhere that item is used.
- Attribute 1 can stay bound to the parent list. Attribute 2 can be bound to that list's nested list. On a movement, attribute 2 then offers only the sub-items of the chosen attribute 1 item.
- The same rule applies to attribute 3 under attribute 2, and to debit, credit, and asset rows. Saving a pair that does not belong together is rejected, and changing the parent clears a child choice that no longer fits.

Assumptions:

- Nesting is one level. A nested list cannot have its own nested list.
- A root list has at most one nested list.
- Sub-item names are unique under one parent item, not across the whole nested list.
- Existing lists remain root lists. No items are rewritten.

## Capabilities

### New Capabilities

- `nested-list-catalog`: The Lists page can add one nested list to a root list and manage sub-items under each parent item, using `list_id` and `item_id`.
- `nested-attribute-values`: A later attribute slot bound to a nested list only accepts sub-items of the item chosen on the previous slot.

### Modified Capabilities

- None. `openspec/specs/` has no capabilities yet.

## Impact

- `list_f` / `list_d` and the Lists page (`web/dimensions.js` `renderLists`).
- Movement attribute editors for debit, credit, and asset rows, plus the save path that writes `attribute_N_item_id`.
- This is the step before `encrypted-ledger-duckdb`. That change keeps `row_hash` so these item ids still attach. It does not define nesting.
