# Spec Delta

## Purpose

The catalog holds two root lists, and each of those lists holds one nested list whose items belong to a single parent item.

## ADDED Requirements

### Requirement: At most two root lists
The Lists page SHALL allow at most two root lists. Creating a third root list SHALL be rejected, and the two existing root lists SHALL stay unchanged.

#### Scenario: A third root list is rejected
- **WHEN** the person already has two root lists and creates another
- **THEN** the page rejects the create and both existing lists remain

### Requirement: One nested list per root list
Each root list SHALL have at most one nested list. A nested list SHALL sit only under a root list. A nested list SHALL NOT gain its own nested list. Creating a second nested list for a root that already has one SHALL be rejected.

#### Scenario: The second nested list is rejected
- **WHEN** a root list already has a nested list and the person adds another
- **THEN** the page rejects the create and the existing nested list remains

#### Scenario: A nested list cannot be nested again
- **WHEN** the person adds a nested list under a list that is itself nested
- **THEN** the page rejects the create

### Requirement: Sub-items belong to one parent item
A nested list's items SHALL each record the parent item they belong to. That parent item SHALL be an item of the nested list's root list. The same sub-item name MAY exist under two different parent items. A name SHALL be unique under one parent item. Renaming a sub-item SHALL change that name everywhere the item is used.

#### Scenario: The same name under two parents
- **WHEN** Rent and Netflix are items of one root list and each gains a sub-item named Standard
- **THEN** both sub-items are saved, each pointing at its own parent item

#### Scenario: A duplicate under one parent is rejected
- **WHEN** Rent already has a sub-item named Standard and the person adds Standard under Rent again
- **THEN** the page rejects the duplicate and the original sub-item remains
