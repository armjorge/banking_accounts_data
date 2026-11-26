# Spec Delta

## Purpose

When a later attribute is bound to a nested list, its choices are only the sub-items of the item chosen on the previous attribute.

## ADDED Requirements

### Requirement: A slot can bind to a nested list
The Lists page SHALL let the person bind a slot to a nested list only when the previous slot is bound to that nested list's parent list. Attribute 1 SHALL NOT be bound to a nested list. Binding attribute 2 to Recurring's nested list SHALL require attribute 1 to be bound to Recurring. The same rule SHALL apply from attribute 2 to attribute 3.

#### Scenario: Attribute 2 binds to Recurring's nested list
- **WHEN** attribute 1 is bound to Recurring and the person binds attribute 2 to Recurring's nested list
- **THEN** the setting is saved

#### Scenario: Attribute 2 cannot bind to a nested list alone
- **WHEN** attribute 1 is free text or bound to a different list and the person binds attribute 2 to Recurring's nested list
- **THEN** the page rejects the binding and the previous setting remains

#### Scenario: Attribute 1 cannot bind to a nested list
- **WHEN** the person binds attribute 1 to a nested list
- **THEN** the page rejects the binding

### Requirement: Child choices follow the chosen parent item
On a debit, credit, or asset movement, a slot bound to a nested list SHALL offer only sub-items whose parent `item_id` is the item selected on the previous slot. When the previous slot has no item, the nested slot SHALL offer no sub-items. Choosing a parent item SHALL clear a child item that does not belong to it. Saving SHALL reject a child `item_id` whose parent is not the selected parent item. Adding a new sub-item from the movement SHALL create it under the currently selected parent item.

#### Scenario: Attribute 2 lists only Rent's sub-items
- **WHEN** attribute 1 is Rent and attribute 2 is bound to Recurring's nested list
- **THEN** attribute 2 offers Apartment and Storage and does not offer a sub-item linked to Netflix

#### Scenario: No parent item means no child choices
- **WHEN** attribute 1 has no item selected
- **THEN** attribute 2 offers no sub-items

#### Scenario: Changing the parent clears a child that no longer fits
- **WHEN** attribute 2 is Apartment under Rent and the person changes attribute 1 to Netflix
- **THEN** attribute 2 is cleared before the movement is saved

#### Scenario: A mismatched pair is rejected
- **WHEN** a save sets attribute 1 to Rent and attribute 2 to a sub-item whose parent is Netflix
- **THEN** the movement is not saved and the stored item ids stay as they were

#### Scenario: A new sub-item is created under the selected parent
- **WHEN** attribute 1 is Rent and the person adds Standard from the attribute 2 control
- **THEN** Standard is stored as a sub-item whose parent `item_id` is Rent's `item_id`
