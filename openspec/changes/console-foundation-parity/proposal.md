# Proposal

## Why

The signed-in Strm Bank site is a single scrolling ribbon of pages, and there is no authenticated backup of a person's banking data. The console built on `bootstrap-platform-foundation` in `pchs20/decolonia-office` (archived as `openspec/changes/archive/2026-06-14-bootstrap-platform-foundation`; the branch `cursor/bootstrap-platform-foundation-spec-4d3a` is not on GitHub) already defines a persistent navigation shell, a home dashboard, and a backup download whose failures cannot be mistaken for a complete archive. This app should reach that same level of interaction and backup safety for its own data.

## What Changes

- Add a persistent signed-in shell: desktop top navigation with the current section marked, a mobile bottom tab bar, and sign-out on every page.
- Give both Cognito roles the same section set: Home, Statements, Investments & Assets, Dimensions, Lists, API tokens, and Settings. Admins keep any extra operator pages that are not in that set.
- Add a home dashboard of recent statement uploads and asset activity, with empty states and links into those sections.
- Add a Settings backup that downloads one ZIP of the signed-in user's active banking data and stored files. Preparation disables a second request, a failure is shown as a failure, and the download does not write application data.
- Add a documented local connectivity check for the web app, the statements API, and Postgres. The check names the dependency that failed.

Assumptions:

- Office domains from that repo (clients, budgets, invoices, workers, Catalan/Spanish/English toggle, Google sign-in, Supabase) stay out of this product.
- The runtime stays the current one: static `web/`, Cognito, Neon Postgres, S3, and the Streamlit control plane. This change does not introduce pnpm, Next.js, NestJS, Docker MinIO, or a new monorepo.

## Capabilities

### New Capabilities

- `signed-in-navigation-shell`: Persistent navigation, section set, and sign-out for the signed-in site.
- `home-dashboard`: Home page of recent work and shortcuts into the existing sections.
- `data-backup-export`: Authenticated, stateless ZIP backup of the signed-in user's active banking data and files.
- `local-development-connectivity`: Documented local startup and a connectivity check that reports which dependency failed.

### Modified Capabilities

- None. `openspec/specs/` has no capabilities yet.

## Impact

- `web/` signed-in rendering (`app.js`, `master.js`, `dimensions.js`) and a new settings/backup view.
- Statements API: backup assembly and a health/connectivity route. Backup reads Postgres and the environment data bucket; it does not change statement ingest, GraphQL, or DDL.
- README local-run steps. The Streamlit control plane stays the place that deploys AWS and publishes the site.
