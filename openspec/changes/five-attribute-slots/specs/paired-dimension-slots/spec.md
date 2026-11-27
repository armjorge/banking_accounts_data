# Spec Delta

## Purpose

Every movement is classified in five fixed slots: two lists, the sublist of each, and one free-text note.

## ADDED Requirements

### Requirement: Five slots in a fixed order
A debit, credit, or asset movement SHALL show five attributes in this order: list 1, the sublist of list 1, list 2, the sublist of list 2, and free text. The person MAY rename each label. The roles SHALL NOT be rearranged or bound to a different list. List 1 and list 2 SHALL be the two root lists. Each sublist slot SHALL be that root list's nested list.

#### Scenario: The editor shows the five roles
- **WHEN** the person opens a movement in the dimension editor
- **THEN** the editor shows list 1, its sublist, list 2, its sublist, and free text, in that order

### Requirement: A list value is optional
List 1 and list 2 SHALL each accept an item of that root list, or no item. Saving with either list empty SHALL keep the movement and SHALL NOT require the other list.

#### Scenario: Only list 1 is filled
- **WHEN** the person sets list 1 to Rent and leaves list 2 empty
- **THEN** the movement is saved with Rent on list 1 and no item on list 2

### Requirement: A sublist follows its list item
A sublist slot SHALL offer only sub-items whose parent is the item selected on that slot's list. When that list item is empty, the sublist slot SHALL offer no sub-items and SHALL NOT accept a value.

#### Scenario: Rent shows only its sub-items
- **WHEN** list 1 is Rent and that list has a nested list
- **THEN** the sublist of list 1 offers Apartment and Storage and does not offer a sub-item of Netflix

#### Scenario: An empty list has no sub-items
- **WHEN** list 1 has no item selected
- **THEN** the sublist of list 1 offers no sub-items

### Requirement: A sublist save matches the selected list item
Changing or clearing the list item SHALL clear a sublist item that does not belong to the new item. Saving SHALL reject a sublist item whose parent is not the selected list item, and the stored ids SHALL stay as they were. Adding a new sub-item from the sublist control SHALL create it under the selected list item.

#### Scenario: Changing the list item clears a sub-item that no longer fits
- **WHEN** the sublist of list 1 is Apartment under Rent and the person changes list 1 to Netflix
- **THEN** the sublist of list 1 is cleared before the movement is saved

#### Scenario: A mismatched pair is rejected
- **WHEN** a save sets list 1 to Rent and the sublist of list 1 to a sub-item whose parent is Netflix
- **THEN** the movement is not saved and the stored ids stay as they were

#### Scenario: A new sub-item is created under the selected item
- **WHEN** list 1 is Rent and the person adds Standard from the sublist of list 1
- **THEN** Standard is stored as a sub-item whose parent item is Rent

### Requirement: The fifth slot is free text
The fifth attribute SHALL be free text. It SHALL NOT be bound to a list. Text saved there SHALL be shown unchanged on that movement.

#### Scenario: A note is saved as text
- **WHEN** the person types a note in the fifth attribute and saves
- **THEN** the movement shows that note and no list item is created for it

### Requirement: A sub-item is not stored on its list slot
The list slot SHALL store the root item. The sublist slot SHALL store the sub-item. A save SHALL NOT store a sub-item id on the list slot.

#### Scenario: Rent and Apartment occupy two slots
- **WHEN** the person saves list 1 as Rent and the sublist of list 1 as Apartment
- **THEN** list 1 shows Rent and the sublist of list 1 shows Apartment
