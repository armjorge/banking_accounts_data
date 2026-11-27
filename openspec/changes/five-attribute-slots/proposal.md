# Proposal

## Why

Binding any of three attributes to any list, and then hanging a sublist off whichever slot happens to be next, makes a movement hard to read and easy to save wrong. Dimensions need a fixed shape: two lists, the sublist of each, and one free-text note.

## What Changes

- **BREAKING**: A movement has five attributes, in this order: list 1, sublist of list 1, list 2, sublist of list 2, free text. The person may leave a list empty. A sublist value is offered and saved only when that list's item is not empty, and only sub-items of the chosen item.
- **BREAKING**: The catalog holds at most two root lists. Each root list has at most one nested list. A third root list, or a second nested list on the same root, is rejected.
- **BREAKING**: Remove the nested-attribute-lists binding model. A slot is no longer chosen from any list, a nested list is no longer bound as "the next attribute," and a sub-item is no longer stored on the parent attribute.
- The five labels may be renamed. The roles stay fixed. The names list 1 and sublist 1 in this change are only names for those roles.
- Existing values are moved onto the slot that matches their role: a root item stays on its list slot, a sub-item moves to that list's sublist slot, and free text moves to the fifth slot.

Assumptions:

- Filling list 1 or list 2 is optional. Empty means the person chose not to classify that movement with that list.
- Changing or clearing a list item clears a sublist item that no longer belongs to it.
- When more than two root lists already exist, the two lists already used as attribute 1 and attribute 2 are the two that remain active. Further root lists stay in the database but are not offered, and creating another root list is rejected until one of the two is deleted.

## Capabilities

### New Capabilities

- `two-list-catalog`: At most two root lists, each with at most one nested list, and sub-items that belong to one parent item.
- `paired-dimension-slots`: Five fixed movement attributes: list 1, its sublist, list 2, its sublist, and free text.

### Modified Capabilities

- None. `openspec/specs/` has no capabilities yet. This change replaces the behavior described in `nested-attribute-lists`, which has not been archived.

## Impact

- Dimension columns on debit, credit, and asset rows grow from three attributes to five. Saves, the Lists page, the dimension editor, and readers that show attribute names follow the fixed roles.
- One-time move of existing item ids and free text onto the matching slot. A sub-item id that was stored on the parent attribute moves to that list's sublist slot. A second list's item id that was stored on attribute 2 moves to the list 2 slot.
- `encrypted-ledger-duckdb` still expects the attribute item ids to travel with a movement. That change must carry five attributes when it is applied, not three.
