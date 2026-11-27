# Tasks

## 1. Nested list catalog

- [x] 1.1 Add `parent_list_id` on `list_f` and `parent_item_id` on `list_d`, with one nested list per root list and no nesting under a nested list. Verify a Postgres test that Recurring gains one nested `list_id`, a second nested list is rejected, and a nested list cannot gain its own nested list.
- [x] 1.2 On the Lists page, add and rename sub-items under a parent `item_id`, with the name unique under that parent item only. Verify in the browser that Apartment and Storage appear under Rent, Standard can also exist under Netflix, a duplicate under Rent is rejected, and renaming a sub-item changes the name on a movement that stores that `item_id`.

## 2. Attribute choices

- [x] 2.1 Bind a slot to a nested list only when the previous slot is bound to that list's parent, and refuse binding attribute 1 to a nested list. Verify a test that attribute 2 saves when attribute 1 is Recurring, and that the other two bindings are rejected.
- [x] 2.2 Filter debit, credit, and asset attribute editors to the selected parent item, clear a child that no longer fits, reject a mismatched save, and create a new sub-item under the selected parent. Verify tests for Rent showing only its sub-items, an empty parent offering none, a parent change clearing the child, a mismatched save leaving the stored ids unchanged, and a new Standard row whose `parent_item_id` is Rent.

## Workflow follow-up

- Archive this change after the implementation is reviewed and the specs are synced.
