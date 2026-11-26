# Spec Delta

## Purpose

Let a person add one nested list under a root list and attach sub-items to each parent item, using the existing list and item ids.

## ADDED Requirements

### Requirement: A root list can have one nested list
The Lists page SHALL let a person add one nested list to a root list. The nested list SHALL be its own `list_id` and SHALL record the parent list's `list_id`. A root list SHALL have at most one nested list. A nested list SHALL NOT have a nested list of its own. Existing lists SHALL remain root lists.

#### Scenario: Add a nested list to Recurring
- **WHEN** the person adds a nested list to the root list Recurring
- **THEN** the Lists page shows that nested list under Recurring, with its own `list_id` linked to Recurring's `list_id`

#### Scenario: A second nested list is refused
- **WHEN** Recurring already has a nested list and the person tries to add another
- **THEN** the page rejects it and Recurring still has one nested list

#### Scenario: A nested list cannot nest again
- **WHEN** the person tries to add a nested list to a list that is already nested
- **THEN** the page rejects it

### Requirement: Sub-items belong to one parent item
Each item of a nested list SHALL be a `list_d` row with its own `item_id` and SHALL record the parent item's `item_id`. The person SHALL be able to add more than one sub-item to the same parent item and rename any of them. Two sub-items under the same parent item SHALL NOT share a name, ignoring case. The same name MAY be used under a different parent item. Renaming a sub-item SHALL show the new name on every movement that stores that `item_id`.

#### Scenario: Two sub-items under one parent item
- **WHEN** the person adds Apartment and Storage under the Recurring item Rent
- **THEN** both appear under Rent, each with its own `item_id`, and both record Rent's `item_id`

#### Scenario: The same name under another parent item
- **WHEN** Standard already exists under Rent and the person adds Standard under Netflix
- **THEN** both sub-items exist, each linked to its own parent `item_id`

#### Scenario: A duplicate name under one parent item is refused
- **WHEN** Apartment already exists under Rent and the person adds Apartment under Rent again
- **THEN** the page rejects the duplicate and Rent still has one Apartment

#### Scenario: Renaming a sub-item updates movements
- **WHEN** a movement stores a sub-item `item_id` and the person renames that sub-item
- **THEN** the movement shows the new name
