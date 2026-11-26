# Spec Delta

## Purpose

Let a signed-in person download one complete backup of their active banking data, and make a failed backup impossible to mistake for a successful one.

## ADDED Requirements

### Requirement: Download one backup from Settings
Settings SHALL offer `Download backup ZIP` to a signed-in person. While a backup is being prepared, that control SHALL be disabled so a second backup cannot start. The system SHALL show that preparation is in progress until the ZIP download begins or the attempt fails.

#### Scenario: A signed-in person downloads a backup
- **WHEN** a signed-in person chooses `Download backup ZIP`
- **THEN** the system prepares one archive and the browser downloads a ZIP file

#### Scenario: A second request cannot start during preparation
- **WHEN** a backup is being prepared
- **THEN** `Download backup ZIP` is disabled and another backup request from that panel does not start

### Requirement: Reject an unauthenticated backup
The system SHALL reject a backup request that has no valid signed-in session, using the same authentication failure as the other signed-in banking APIs. It SHALL NOT return a ZIP.

#### Scenario: A request without a session
- **WHEN** a backup request arrives without a valid signed-in session
- **THEN** the system rejects it and does not return a ZIP

### Requirement: The ZIP holds the person's active data and files
The ZIP SHALL contain one workbook at the archive root named `Strm-Bank-data.xlsx` with the sheets `Accounts`, `Statements`, `Assets`, `Lists`, and `Transfers`. Those sheets SHALL include stable identifiers for the rows that are still stored for the signed-in person. The ZIP SHALL also contain the current stored statement and asset files for that person. Deleted rows and another person's rows SHALL be absent.

#### Scenario: Workbook sheets and root path
- **WHEN** a backup archive is generated
- **THEN** `Strm-Bank-data.xlsx` is at the ZIP root and contains the sheets `Accounts`, `Statements`, `Assets`, `Lists`, and `Transfers`

#### Scenario: Stored files are included
- **WHEN** the person has stored statement or asset files
- **THEN** the archive contains those current files

#### Scenario: Deleted and foreign rows are absent
- **WHEN** a row was deleted, or it belongs to another person
- **THEN** that row is not in the workbook and its file is not in the archive

### Requirement: File paths follow year and quarter
Each included file SHALL be stored under `Statements/<year>/<quarter>/` or `Assets/<year>/<quarter>/`. `<quarter>` SHALL be `Q1`, `Q2`, `Q3`, or `Q4` for the calendar quarter of that file's period. Repeating the export from the same stored data SHALL use the same relative paths and file names. The outer ZIP name MAY include a timestamp.

#### Scenario: A March statement file is under Q1
- **WHEN** a statement file belongs to a March period
- **THEN** its archive path starts with `Statements/`, contains that year, and contains `Q1`

#### Scenario: Paths stay stable across repeated exports
- **WHEN** the same stored data is exported twice
- **THEN** the relative paths and file names inside the two archives match

### Requirement: Backup does not change stored data
Generating or downloading a backup SHALL NOT insert, update, or delete banking records, and SHALL NOT import the archive.

#### Scenario: Two downloads leave the data unchanged
- **WHEN** a person downloads two backups without otherwise changing their data
- **THEN** each archive is built from the current stored data and the stored data is unchanged

### Requirement: A failed backup is not reported as complete
If the workbook or a required file cannot be assembled, the system SHALL show an error in Settings, SHALL re-enable `Download backup ZIP`, and SHALL NOT start a download labeled as a complete backup. An empty sheet SHALL still exist when the person has no rows for that sheet.

#### Scenario: Assembly fails
- **WHEN** a required file cannot be read or the archive cannot be finished
- **THEN** Settings shows an error, the download control is enabled again, and no complete-backup download starts

#### Scenario: A person has no asset rows
- **WHEN** the person has no asset rows
- **THEN** the workbook still contains an `Assets` sheet and the download can succeed
