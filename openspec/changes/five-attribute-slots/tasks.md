# Tasks

## 1. Catalog cap

- [x] 1.1 Reject a third root list and a second nested list on the same root, in the database and on the Lists page. Verify a Postgres test that two root lists save, a third is rejected, one nested list per root saves, and a second nested list or a nested list under a nested list is rejected.
- [x] 1.2 Keep sub-items under one parent item, with the same name allowed under a different parent and a duplicate under the same parent rejected. Verify the existing nested-list test still passes for Apartment and Storage under Rent, Standard under Netflix, and a repeated Standard under Rent.

## 2. Five slots

- [x] 2.1 Add `attribute_4`, `attribute_4_item_id`, and `attribute_5` on debit, credit, and asset dimension rows, and assign list 1 and list 2 by root-list age. Verify a test that the older root list is list 1, its nested list is the first sublist, the newer root list is list 2, and the fifth slot stores text without creating a list item.
- [x] 2.2 Save list and sublist pairs only when the sub-item belongs to the selected list item, clear a child that no longer fits, and stop storing a sub-item id on the list slot. Verify tests for Rent showing only its sub-items, an empty list offering none, a parent change clearing the child, a mismatched save leaving the stored ids unchanged, and Rent plus Apartment stored on two slots.
- [x] 2.3 Move existing values onto those roles: a sub-item id on attribute 1 becomes the sublist slot and attribute 1 becomes its parent item; a second root list's item on attribute 2 moves to list 2; leftover free text moves to attribute 5. Verify a test with one row in the pre-change shape that lands on the five slots described above.
- [x] 2.4 Render the five controls in the dimension editor and remove slot-to-list binding from the Lists page. Verify in the browser that the order is list 1, its sublist, list 2, its sublist, and free text, that a sublist is empty until its list item is chosen, and that creating a third root list is rejected.

## Workflow follow-up

- Archive `five-attribute-slots` after the implementation is reviewed. Leave `nested-attribute-lists` unarchived until this change has replaced it, so the old binding behavior is not copied into `openspec/specs/`.
