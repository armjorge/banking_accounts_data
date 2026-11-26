# Spec Delta

## Purpose

Store every banking movement in one ledger so debit, credit, open, future, and asset rows are no longer split across master tables.

## ADDED Requirements

### Requirement: One ledger holds every movement
The system SHALL store statement and asset movements in a single ledger table. Each row SHALL record its kind as debit, credit, or asset, and its state as closed, open, or future. The kinds and states that exist today SHALL still be representable, including open debit, open credit, future debit, and asset movements.

#### Scenario: A debit movement and an asset movement share the table
- **WHEN** a closed debit movement and a closed asset movement are stored
- **THEN** both rows are in the single ledger and each row's kind identifies which one it is

#### Scenario: An open credit movement keeps its state
- **WHEN** an open credit movement is stored
- **THEN** the ledger row has kind credit and state open

### Requirement: Migrated rows keep their values
A one-time copy SHALL move existing rows from `master_debit_closed_f`, `master_credit_closed_f`, `master_debit_open_f`, `master_credit_open_f`, `master_debit_future_f`, `open_debit_f`, `open_credit_f`, `master_closed_aaccandass_f`, and `master_open_aaccandass_f` into the ledger. Each copied row SHALL keep its `row_hash`, dates, amounts, concept, account, and file identity. After the copy, new writes SHALL go only to the ledger.

#### Scenario: A copied debit row matches the old row
- **WHEN** the copy finishes for a closed debit row
- **THEN** the ledger row has the same `row_hash`, transaction date, amounts, and concept as the old row

#### Scenario: A new upload does not write the old tables
- **WHEN** a person uploads a statement after the copy
- **THEN** the new movements are inserted into the ledger and the old master tables gain no rows

### Requirement: Readers still see today's movement facts
Screens and APIs that show movements SHALL read the ledger and SHALL show the same account, date, concept, and amount a person could see from the old table for that row. Dimension rows SHALL still attach by `row_hash`.

#### Scenario: A statement screen shows a migrated amount
- **WHEN** a person opens a period whose rows were copied
- **THEN** the screen shows the same amounts and concepts as before the copy

#### Scenario: A dimension stays attached
- **WHEN** a movement had an attribute stored against its `row_hash`
- **THEN** that attribute still resolves for the ledger row with that `row_hash`
