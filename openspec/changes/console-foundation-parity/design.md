# Design

## Context

See proposal.md for why. Today `web/app.js` sends admins to `renderMasterBanking` in `web/master.js` and everyone else to `renderUserPages` in `web/dimensions.js`. Both draw a button ribbon. Admin pages omit Investments & Assets. There is no Home or Settings section.

The published statements API is `infra/lambda/statements.ts`, behind API Gateway, with the data bucket prefix `curated/{tenant}/`. `apps/statements/local_api.py` is the local preview twin and is what the Python tests drive. Cognito ID tokens already authorize those routes. The Streamlit app in `apps/config_console/` deploys environments and publishes `web/`; it is not the signed-in console.

## Goals / Non-Goals

**Goals:**

- One shell in the existing static site for the seven sections in the navigation spec.
- Home and backup built from data the signed-in user already owns.
- The same backup and health behavior in the Lambda and in the local preview API.
- A documented check a developer can run against that local API.

**Non-Goals:**

- Replacing Cognito, Neon, S3, CDK, or the static site.
- Moving deploy, DDL, or publish actions out of the Streamlit control plane.
- Translating the UI, or copying office documents, workers, or catalogs from Decolonia Office.

## Decisions

### Keep the static site and add a shared shell

The signed-in renderers move under one shell module that both `renderMasterBanking` and `renderUserPages` use. Wide layout keeps a top bar; narrow layout adds a bottom bar via the existing stylesheet's breakpoint. Sign-out stays the current Cognito logout.

Alternative: rebuild the site as a Next.js app, as the source foundation did. Rejected because this product's pages, auth, and publish path already work, and the proposal keeps that runtime.

### Home reads the existing list routes

Home calls the authenticated statement and asset list routes and shows the first five newest rows. Add a query parameter or a small route only if those lists do not already return account, period or movement date, and time, limited to the caller.

Alternative: a dedicated dashboard aggregate. Rejected until the lists prove insufficient.

### Backup is assembled on the API, then downloaded

Add `POST /backup` on both API implementations. It resolves the caller the same way other routes do, reads only that caller's still-stored rows, and builds `Strm-Bank-data.xlsx` plus the current `curated/{tenant}/` objects. Paths use the file's period month to choose `Statements/<year>/Q#/` or `Assets/<year>/Q#/`.

API Gateway cannot return a large body. If the finished ZIP fits in the response, return it as the download. If it does not, write it to a non-listed object under that caller's prefix with a short lifetime and return a short-lived download URL for that one object. Either way the browser receives one ZIP. If assembly fails, delete any partial object, return an error, and do not emit a URL or a body described as a complete backup.

The workbook query lives in SQL so the Lambda and the preview API share row selection. File bytes stay in the API process because only it can read the bucket. Local tests use a fake object store. The preview API fails the backup when a required object is missing, matching the spec.

Alternative: build the ZIP only in the browser from existing GETs. Rejected because a failed file read would be easy to save as a partial archive, which the spec forbids.

### Connectivity check hits the local API

Add `GET /health` and `GET /health/connectivity` on the preview API. `/health` reports the process. `/health/connectivity` runs a Postgres probe and returns which dependency failed. A small script runs those requests and exits non-zero with that text. Document it next to the existing `uv` and preview instructions. The published Lambda gets the same health routes so the contract is not preview-only, but the documented developer check targets the local API.

Alternative: Docker Compose for Postgres and MinIO, as the original foundation change did. Rejected. Local Postgres is already how the tests run, and object storage in production is the existing S3 bucket.

## Risks / Trade-offs

- [ZIP larger than the API response limit] → Spill to a short-lived private object and return one download URL. Do not stream a partial ZIP.
- [Lambda and preview API drift] → Shared SQL for row selection, and a Python test plus a handler test that lock the ZIP paths and the failure response.
- [Backup duration on a large history] → The Settings control stays disabled until the request settles. A timeout is a failure, not a success.
- [Admin used to lack Investments & Assets] → The shared section set adds it. No data rules change.

## Migration Plan

Publish the API before the site so Settings and health exist when the new pages call them. The site publish remains the Streamlit "Publish frontend" action. Rollback is the previous site bundle and the previous Lambda. Backup objects use a prefix that no other feature reads, so a rollback does not leave the app dependent on them. No DDL is required for navigation or home. The workbook SQL is additive.

## Open Questions

None. Sheet names, section set, and the decision to keep this runtime are fixed by the specs and the proposal.
