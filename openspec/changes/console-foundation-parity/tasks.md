# Tasks

## 1. Signed-in shell

- [ ] 1.1 Add one shell used by both signed-in renderers, with Home, Statements, Investments & Assets, Dimensions, Lists, API tokens, and Settings, a marked current section, sign-out, a top bar on a wide viewport, and a bottom bar on a narrow viewport. Verify in the browser that a non-admin and an admin can open each shared section, that sign-out returns to the sign-in screen, and that the bottom bar does not cover the page on a narrow viewport.
- [ ] 1.2 Point each existing section at its current renderer, and leave any extra admin-only page reachable. Verify the statements, dimensions, lists, API tokens, and assets flows still load inside the shell for the role that could open them before.

## 2. Home dashboard

- [ ] 2.1 Load the signed-in person's recent statement uploads and asset movements from the existing list routes, showing at most five newest entries with account and period or movement date, plus empty states and controls that open those sections. Verify with seeded rows that another person's records are absent, an entry opens the matching section, and an empty account shows the empty state rather than a blank page.

## 3. Backup export

- [ ] 3.1 Add the shared SQL that returns the caller's still-stored Accounts, Statements, Assets, Lists, and Transfers rows, including stable ids, and omits deleted rows. Verify a Python test against Postgres: the caller's rows are present, a deleted row is absent, and another person's row is absent.
- [ ] 3.2 Add `POST /backup` on the local preview API and on `infra/lambda/statements.ts`. Build `Strm-Bank-data.xlsx` at the ZIP root and place current files under `Statements/<year>/Q#/` or `Assets/<year>/Q#/`. Return the ZIP when it fits in the API response; otherwise write one short-lived unlisted object and return its download URL. On a missing file, return an error and leave no partial object. Verify tests for sheet names, a March file under `Q1`, identical inner paths on two runs, unchanged row counts after export, a missing object returning an error, and a request without a session returning the usual auth error and no ZIP.
- [ ] 3.3 Add the Settings control `Download backup ZIP`, disable it while the request is in flight, and surface a failure without starting a complete-backup download. Verify in the browser that a second click does nothing during preparation, a forced API error re-enables the control and shows the error, and a successful call downloads one ZIP.

## 4. Local connectivity

- [ ] 4.1 Add `GET /health` and `GET /health/connectivity` to the preview API and the Lambda. The connectivity route succeeds only when Postgres answers, and names Postgres when it does not. Verify a Python test for the healthy probe and for a refused database connection.
- [ ] 4.2 Add a repository command that calls the local connectivity routes and document the first-run flow in the README. Verify the documented command exits 0 against a running local API and exits non-zero, naming the API, when the API is stopped.

## Workflow follow-up

- Archive this change after the implementation is reviewed and the specs are synced.
