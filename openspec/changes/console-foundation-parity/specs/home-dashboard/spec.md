# Spec Delta

## Purpose

Give a signed-in person a home page that shows recent banking work and opens the sections they use next.

## ADDED Requirements

### Requirement: Home shows recent statement work
The home page SHALL list up to five of the signed-in person's most recent statement uploads, newest first. Each entry SHALL show the account, the period, and the upload time, and SHALL open that statement context. A control SHALL open the Statements section.

#### Scenario: Recent uploads appear on home
- **WHEN** the home page finishes loading and the person has statement uploads
- **THEN** it shows at most five uploads, newest first, each with account, period, and upload time

#### Scenario: An upload entry opens Statements
- **WHEN** the person chooses a recent upload entry
- **THEN** the Statements section opens on that account and period

#### Scenario: No statement uploads yet
- **WHEN** the person has no statement uploads
- **THEN** the statement area shows an empty state and still offers the control that opens Statements

### Requirement: Home shows recent asset work
The home page SHALL list up to five of the signed-in person's most recent asset movements, newest first. Each entry SHALL show the account and the movement date, and SHALL open Investments & Assets. A control SHALL open that section.

#### Scenario: Recent asset movements appear on home
- **WHEN** the home page finishes loading and the person has asset movements
- **THEN** it shows at most five movements, newest first, each with account and movement date

#### Scenario: No asset movements yet
- **WHEN** the person has no asset movements
- **THEN** the asset area shows an empty state and still offers the control that opens Investments & Assets

### Requirement: Home is limited to the signed-in person
The home page SHALL show only records owned by the signed-in person.

#### Scenario: Another person's records stay hidden
- **WHEN** another person in the same environment has uploads or asset movements
- **THEN** those records do not appear on this person's home page
