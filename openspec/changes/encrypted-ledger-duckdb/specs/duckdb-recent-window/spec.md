# Spec Delta

## Purpose

Give each signed-in person a transient DuckDB table of their decrypted movements for the last three calendar months, and refresh only the part that changed.

## ADDED Requirements

### Requirement: The transient table holds the last three months
The system SHALL keep, for each signed-in person, a transient DuckDB table of that person's decrypted ledger rows whose `txn_date` falls in the current calendar month or the two previous calendar months in America/Mexico_City. Rows older than that window SHALL NOT remain in the table. The table SHALL contain only that person's rows. It SHALL be rebuilt from the ledger after the process that holds it restarts, and it SHALL NOT be the durable store.

#### Scenario: A row from this month is present
- **WHEN** the window is built and the person has a movement dated in the current month
- **THEN** the DuckDB table contains that movement in plaintext

#### Scenario: A row older than three months is absent
- **WHEN** the window is built and the person has a movement dated four calendar months ago
- **THEN** that movement is not in the DuckDB table

#### Scenario: Another person's rows are absent
- **WHEN** the window is built
- **THEN** it contains no row owned by a different person

### Requirement: Updates refresh the smallest correct scope
When the person changes one or more ledger rows inside the window, the system SHALL replace those rows in the DuckDB table. When the person replaces a file or a period, the system SHALL replace every window row in the affected dates. When a change cannot be mapped to specific rows or dates, or the three-month boundary moves, the system SHALL rebuild the whole table. After every refresh the table SHALL again contain exactly the default window.

#### Scenario: Editing one row updates that row
- **WHEN** the person edits one movement inside the window
- **THEN** the DuckDB table shows the new plaintext for that row and leaves the other window rows unchanged

#### Scenario: Replacing a period updates that period
- **WHEN** the person replaces the file for one statement period inside the window
- **THEN** the DuckDB rows for that period match the new file and rows in other periods stay as they were

#### Scenario: An unscoped change rebuilds the table
- **WHEN** a change cannot be tied to particular rows or dates
- **THEN** the DuckDB table is rebuilt and still contains only the last three months
