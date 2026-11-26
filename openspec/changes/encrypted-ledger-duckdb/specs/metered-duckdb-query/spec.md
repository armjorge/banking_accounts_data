# Spec Delta

## Purpose

Let a signed-in person query their DuckDB window, and limit how many of those queries each plan includes.

## ADDED Requirements

### Requirement: A query view runs against the person's window
The signed-in app SHALL offer a view that runs a read-only query against that person's DuckDB window and shows the result rows. The query SHALL NOT modify the window or the ledger. A query that is not read-only SHALL be rejected and SHALL NOT count as a used query.

#### Scenario: A read-only query returns window rows
- **WHEN** the person runs a read-only query and has remaining allowance
- **THEN** the view shows the matching plaintext rows from that person's window

#### Scenario: A write is rejected
- **WHEN** the person submits a query that inserts, updates, or deletes
- **THEN** the view shows an error and the window is unchanged

### Requirement: Query use is limited by plan
The view SHALL show the plan name, how many queries remain, and when the allowance resets. Free and Entry SHALL allow 1 query per calendar week. Plus and Premium SHALL allow 3 queries per calendar day. Weeks start on Monday in America/Mexico_City. A result SHALL contain at most 5000 rows. This allowance SHALL be separate from the GraphQL API allowance. A query over the limit SHALL be rejected, SHALL NOT return rows, and SHALL tell the person which plan applies and when they can query again.

#### Scenario: The view shows the remaining allowance
- **WHEN** a Plus person opens the query view
- **THEN** the view shows the Plus plan, how many of the 3 daily queries remain, and when the day resets

#### Scenario: The next query over the limit is refused
- **WHEN** a Free person has already used the one query for the current week and runs another
- **THEN** the view returns no rows and says the Free allowance resets at the next Monday

#### Scenario: A DuckDB query does not spend a GraphQL call
- **WHEN** the person runs a successful DuckDB query
- **THEN** the GraphQL calls remaining for that person stay the same

#### Scenario: A large result stops at 5000 rows
- **WHEN** a query matches more than 5000 window rows
- **THEN** the view returns 5000 rows and says the result was limited
