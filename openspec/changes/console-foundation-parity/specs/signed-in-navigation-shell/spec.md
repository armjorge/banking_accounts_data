# Spec Delta

## Purpose

Give every signed-in person a persistent way to move between the banking sections and to sign out, on a wide screen and on a phone.

## ADDED Requirements

### Requirement: Signed-in pages use one shell
The system SHALL wrap every signed-in banking page in one navigation shell. The shell SHALL NOT wrap the signed-out sign-in screen.

#### Scenario: Signed-in page shows the shell
- **WHEN** a signed-in person opens any banking section
- **THEN** that section renders inside the navigation shell

#### Scenario: Sign-in screen has no section navigation
- **WHEN** a person is on the sign-in screen
- **THEN** the page does not show section navigation

### Requirement: Wide and narrow navigation
On a wide viewport the shell SHALL show a top bar with a label for each section and SHALL NOT show a bottom tab bar. On a narrow viewport the shell SHALL show a bottom tab bar with one control per section and SHALL keep sign-out reachable. The current section SHALL be marked in whichever bar is visible. Page content SHALL remain reachable and SHALL NOT sit underneath the bottom bar.

#### Scenario: Wide viewport shows labeled top navigation
- **WHEN** a signed-in person views the site on a wide viewport
- **THEN** each section appears as a labeled control in the top bar and no bottom tab bar is shown

#### Scenario: Narrow viewport shows bottom tabs
- **WHEN** a signed-in person views the site on a narrow viewport
- **THEN** a fixed bottom bar shows one control per section and the page content is not covered by that bar

#### Scenario: Current section is marked
- **WHEN** the person is in Statements
- **THEN** the Statements control is marked as the current section

### Requirement: Shared section set
The shell SHALL offer Home, Statements, Investments & Assets, Dimensions, Lists, API tokens, and Settings to every signed-in person. Choosing a section SHALL open that section. A person in the Cognito `admin` group SHALL still be able to open any additional operator page that is not in this set.

#### Scenario: A non-admin person opens Investments & Assets
- **WHEN** a signed-in person who is not an admin chooses Investments & Assets
- **THEN** the Investments & Assets section opens

#### Scenario: An admin person opens the same sections
- **WHEN** a signed-in admin chooses Settings
- **THEN** the Settings section opens

### Requirement: Sign-out from the shell
The shell SHALL offer sign-out on every signed-in page. Choosing it SHALL end the Cognito session and return the person to the sign-in screen.

#### Scenario: Sign-out ends the session
- **WHEN** a signed-in person chooses sign-out
- **THEN** the session is cleared and the sign-in screen is shown
