# Spec Delta

## Purpose

Keep sensitive movement fields encrypted in Postgres so a database reader without the person's key cannot read them, while the signed-in app can show plaintext.

## ADDED Requirements

### Requirement: Sensitive ledger fields are ciphertext in Postgres
The ledger SHALL store concept, amounts, account number, file name, and note as ciphertext. A reader of the database who does not have the owner's key SHALL NOT be able to recover those values. `user_id`, `tenant_id`, `account_id`, kind, state, `txn_date`, and `row_hash` SHALL remain readable so the system can select a person's rows for a date range without decrypting older history.

#### Scenario: Amounts and concepts are not plaintext in the table
- **WHEN** a movement is saved and the ledger table is read with SQL
- **THEN** the concept, amounts, account number, file name, and note are ciphertext rather than the values the person typed or uploaded

#### Scenario: The date and owner stay selectable
- **WHEN** the system selects one person's rows for a date range
- **THEN** it can filter on `user_id` and `txn_date` without decrypting rows outside that range

### Requirement: The owner sees plaintext
The signed-in app SHALL show the owner's movements in plaintext. Another person's key SHALL NOT decrypt those rows. Losing the key SHALL leave the stored ciphertext unreadable by the app.

#### Scenario: The owner opens a movement
- **WHEN** the owner opens a movement in the app
- **THEN** the concept, amounts, and account number are shown in plaintext

#### Scenario: A different person cannot decrypt the row
- **WHEN** a different signed-in person requests that movement
- **THEN** the system does not return its plaintext
