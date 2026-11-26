# Spec Delta

## Purpose

Let a signed-in person download one period as normalized rows and PDFs, or as the original source files whole.

## ADDED Requirements

### Requirement: Export one period in normalized or raw form
The signed-in app SHALL offer an export view for a single statement period. The person SHALL choose normalized or raw. Normalized SHALL download a CSV of that person's decrypted ledger rows for the period and the PDF files stored for that period. Raw SHALL download only the original source files stored for that period, each file complete. The view SHALL NOT offer a raw download of selected rows, selected columns, or part of a source file.

#### Scenario: Normalized download contains rows and PDFs
- **WHEN** the person exports a period as normalized and that period has movements and a stored PDF
- **THEN** the download contains a CSV of those decrypted movements and that PDF

#### Scenario: Raw download is the whole source file
- **WHEN** the person exports a period as raw and the period was loaded from a source file
- **THEN** the download contains that entire source file and does not contain a trimmed copy of it

#### Scenario: Raw export has no row subset
- **WHEN** the person is on the raw export choice
- **THEN** the view does not offer a control that downloads only some rows or part of a source file

### Requirement: An empty or foreign period is not someone else's files
The export SHALL include only the signed-in person's files and rows for the chosen period. When the period has no source file, raw export SHALL say so and SHALL NOT invent a file. When the period has no movements, normalized export SHALL still return a CSV with the ledger headers and no data rows.

#### Scenario: Another person's file is absent
- **WHEN** the person exports a period
- **THEN** the download contains none of another person's files or rows

#### Scenario: Raw export with no source file
- **WHEN** the person exports as raw a period that has no stored source file
- **THEN** the view says there is no source file and does not download a partial archive

#### Scenario: Normalized export with no movements
- **WHEN** the person exports as normalized a period with no movements
- **THEN** the CSV has the ledger headers and no data rows
