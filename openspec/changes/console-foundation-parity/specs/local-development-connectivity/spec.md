# Spec Delta

## Purpose

Let a developer prove that the local web app can reach the statements API and that the API can reach Postgres, and see which dependency failed.

## ADDED Requirements

### Requirement: Documented local startup
The repository documentation SHALL describe one local setup flow that installs dependencies, configures the environment, and runs the web app against the statements API and Postgres. A developer following that flow SHALL NOT need machine-specific steps beyond the documented prerequisites.

#### Scenario: First local setup
- **WHEN** a developer follows the documented setup flow on a machine with the documented prerequisites
- **THEN** they can run the web app, the statements API, and Postgres connectivity locally

### Requirement: Connectivity check names the failed dependency
The system SHALL provide a documented check that reports web-to-API reachability and API-to-Postgres reachability. When Postgres is down or misconfigured, the check SHALL fail and SHALL say that Postgres is the unhealthy dependency. When the API is not running, the check SHALL fail and SHALL say that the API is unreachable.

#### Scenario: Healthy local stack
- **WHEN** the web app, the statements API, and Postgres are running with the documented configuration
- **THEN** the connectivity check reports success for the API and for Postgres

#### Scenario: Postgres is unavailable
- **WHEN** the API is running and Postgres is unavailable or misconfigured
- **THEN** the connectivity check fails and identifies Postgres as unhealthy

#### Scenario: API is not running
- **WHEN** the developer runs the check and the statements API is not running
- **THEN** the check fails and identifies the API as unreachable
