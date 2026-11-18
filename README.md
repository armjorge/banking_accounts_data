# banking_accounts_data

Operator control plane: AWS environments, Cognito login, and a Neon `users` table keyed by Cognito `sub`.

This first slice stops when you can sign in on CloudFront and see a row in `cognito_users.users`. App DDL and per-user views come on `feature/app-ddl`.

## What you get

**Once per AWS account** — stack `StrmBank-Control`

- One private config bucket (environment variables live here, not on your laptop)
- SSM pointer `/strm_bank/control/config-bucket`
- IAM policy `StrmBank-Control-Operator`

**Once per named environment** (example `dev`, prefix `strm_bank_dev`) — stack `StrmBank-dev`

- Website bucket + CloudFront
- Data bucket (files later)
- Cognito Lite user pool + hosted UI
- Lambda that upserts Neon `cognito_users.users` after sign-up and sign-in
- SSM under `/strm_bank_dev/*`

Pay-per-use only (no RDS, NAT, ALB, or customer-managed KMS). PostgreSQL is Neon.

## Tools

| Tool | Where you run it |
| --- | --- |
| `uv` + Streamlit | **repository root** |
| `npm` + CDK | **`infra/` only** |
| AWS CLI | any terminal |

Do not `cd infra` and then run Streamlit or `pip install -r apps/...`. Those paths are at the repo root.

## 1. AWS account and login

You need an AWS account, IAM (or root) credentials, and AWS CLI **2.32 or later** so `aws login` works.

```bash
aws --version
aws login
aws sts get-caller-identity
```

`aws sts get-caller-identity` must print JSON with:

- **Account** — 12-digit id, for example `747289880051`
- **Arn** — who you are
- **UserId**

That login is stored on the machine. Streamlit and CDK both use it. You do not paste access keys into the app.

**Region.** This project defaults to `us-east-1`. Use the same region in Streamlit, bootstrap, and Neon if you can. Your Neon host may be in another region; that is fine.

## 2. CDK bootstrap (once per account + region)

This is **not** the product. It only installs CDK’s helper bucket and roles so CloudFormation can deploy.

`$ACCOUNT` is empty unless you set it. This is wrong and becomes `aws:///`:

```bash
npx cdk bootstrap aws://$ACCOUNT/$REGION
```

From the **repository root**, after `aws login`:

```bash
aws sts get-caller-identity --query Account --output text
```

Copy the 12-digit number. Then either:

```bash
./scripts/cdk-bootstrap.sh us-east-1
```

or:

```bash
cd infra
npm install
npx cdk bootstrap aws://YOUR_12_DIGIT_ACCOUNT/us-east-1
cd ..
```

Success looks like: `Environment aws://747289880051/us-east-1 bootstrapped.`

## 3. Open the control plane

Stay at the **repository root** (not `infra/`):

```bash
uv sync
uv run streamlit run apps/config_console/app.py
```

Open http://localhost:8501. The sidebar must show your IAM ARN.

`uv sync` installs `botocore[crt]` so boto3 can read `aws login`. There is no global `streamlit` command; always `uv run streamlit ...`.

If the sidebar says there are no credentials: stop Streamlit, `uv sync`, start it again from the repo root.

## 4. Deploy an environment (`dev`)

In Streamlit:

1. Environment name: `dev`
2. **Create environment and deploy AWS objects**

That deploys `StrmBank-Control` (if needed) and `StrmBank-dev`. First run often takes 5–10 minutes (CloudFront). CDK lines stream in the page and in the terminal.

Cognito **Lite** cannot use Managed Login v2 or refresh-token rotation; the stack already uses Lite-compatible settings.

Optional: attach IAM policy `StrmBank-Control-Operator` to your user if S3/SSM writes fail with AccessDenied. CDK deploy still uses your full AWS login.

## 5. Point this environment at Neon

In the Neon console, copy the connection URI, for example:

```text
postgresql://neondb_owner:YOUR_PASSWORD@ep-....neon.tech/neondb?sslmode=require
```

The password is the segment between `:` and `@`. Paste the **full** URI (it is shown in clear text). Defaults:

- Database: `neondb`
- Users schema: `cognito_users` (this slice)
- App schema: `core` (saved only; **not** applied yet)

**Save variables to config bucket.** That also writes `/strm_bank_dev/neon_database_url` for the login Lambda.

**Test Neon connection**, then **Apply users DDL**. In Neon, schema `cognito_users` should contain table `users` (`user_id`, `cognito_sub`, `email`).

## 6. Publish login and fill the table

1. **Bootstrap users table + login site** (or **Publish frontend only** if the table already exists).
2. **Deploy AWS objects for `dev` again** after pulling this repo’s Lambda (Cognito post-confirm / post-auth upsert). Skip if that function is already on the stack.
3. Open the CloudFront URL from **Deployed outputs** → `web-domain` (`https://….cloudfront.net`).
4. Sign up / sign in. If Cognito says the user is already `CONFIRMED`, use **Sign in**, not another email code.
5. You should see a welcome page with your email and Cognito `sub`.
6. In Neon: `SELECT * FROM cognito_users.users;` — `user_id` is the app key; `cognito_sub` matches the welcome page.

New sign-ins upsert; they do not duplicate the row.

## Run the signed-in page locally

Use this to try `web/` before **Publish frontend only**. Cognito already allows `http://localhost:5173/` as a return address. Another port will be rejected.

`web/config.js` is not in git. After a clone, create it again from the site that is already published:

```bash
curl -fsS "https://YOUR_DOMAIN.cloudfront.net/config.js" -o web/config.js
```

`YOUR_DOMAIN` is **Deployed outputs** → `web-domain`. Then change only these two lines in `web/config.js`. The trailing slash is required:

```javascript
redirectUri: "http://localhost:5173/",
logoutUri: "http://localhost:5173/",
```

If the CloudFront site has never been published, copy `config/web.config.example.js` to `web/config.js` and fill `userPoolId`, `clientId`, `cognitoDomain`, and `apiUrl` from **Deployed outputs**.

From the repository root, leave this running:

```bash
python3 -m http.server 5173 --directory web
```

Open http://localhost:5173/ and sign in with the same Cognito user as the CloudFront site. You are now reading the files in `web/`. Edit them, save, and refresh the browser. Publishing to S3 is only for the CloudFront URL.

Sign-in and the page list work on localhost. Loading and saving banks, account types, and templates calls the admin API, which currently allows only the CloudFront origin. Those saves stay blocked until `http://localhost:5173` is added to that API’s allowed origins and the environment is deployed again.

## Recreating on a new laptop

1. `aws login` and `aws sts get-caller-identity`
2. Clone the repo, `uv sync`, `uv run streamlit run apps/config_console/app.py`
3. Config is already in the control-plane S3 bucket. No `.env` to copy.
4. Bootstrap CDK only if this account/region has never been bootstrapped.
5. Recreate `web/config.js` with the steps in **Run the signed-in page locally**. That file is gitignored.

## Product tiers

Limits are enforced in `public.plans_d` and the `bank_accounts_d` trigger. Applying `sql/006_statement_flow.sql` again resets these caps.

| Plan | Accounts | Curated CSV vault |
| --- | --- | --- |
| Free, and the legacy Entry row | 1 credit card and 1 debit account. Savings uses the debit slot. | No |
| Plus | 10 accounts, any mix | No |
| Premium | 10 accounts, any mix | Yes |

An 11th account is rejected. More than 10 accounts is not another shared plan. It is a private deployment of this same repository in the client's own AWS account and their own Neon project, created again from the config console. That deployment is not a wizard in this MVP.

## File catcher

Only Banorte is loaded. A signed-in user opens an account (bank debit, bank credit card, or savings) and types the account number as text, so `0639` keeps its leading zero. Credit cards also take a cutoff day and a payment window in days (`credit_days` on the lineage example is 20). Debit and savings have no cutoff: the period ends on the last day of the month.

The page then shows the latest period whose cutoff is already in the past, plus the two before it. On 2026-10-20 that is `2026-10`, `2026-09`, `2026-08` for a credit card with cutoff day 6, and `2026-09`, `2026-08`, `2026-07` for a debit account. Each row stores `period_start` and `period_end`. The `YYYY-MM` label is derived from `period_end`. The user can add the previous period or remove an older empty one. The three current periods stay. A period stays pending until its statement CSV is in the closed master. Premium can also attach an optional PDF; that PDF does not clear the pending flag.

CSV text is parsed in Postgres after the browser decodes it. A temporary S3 upload is not used: a rejected file leaves no object and no rows. Premium then copies the same bytes to `curated/{tenant}/{upload}.csv` (or `.pdf`) in the curated bucket. Deleting a file removes that file's rows only. The vault object stays.

Closed masters are append-only. Dimensions in `movement_dimensions_d` are keyed by tenant and `row_hash` and are not deleted with the file or the open book.

### Bank Stream ledgers (sql/011)

Every account has three ledgers, all filled by the same `ingest_statement_csv` pipe and profiles:

| Ledger | Slot | Lands in | Load rule |
| --- | --- | --- | --- |
| Closed (past) | statement slot on a period whose cutoff has passed | `master_debit_closed_f` / `master_credit_closed_f` | Append-only. A repeated `row_hash` is rejected as `already uploaded`. |
| Open (current) | statement slot on the current period: the calendar month for debit, the day after the last cutoff through the next cutoff for credit | `master_debit_open_f` / `master_credit_open_f` (same schema as the closed master) | Per-account replace on every upload. Other accounts keep their rows. Once that period closes, the closed statement replaces the open file. |
| Future (MSI) | installment slot (credit only) | `master_credit_future_f` (named `master_debit_future_f` before 014; same schema as `master_credit_closed_f`) | `Pagos pendientes` `NN/MM` means NN payments still due. Each plan becomes NN rows of `cargos = mensualidad`, dated on the next NN cutoff dates after the as-of date (never the purchase date). The last payment absorbs a sub-peso rounding gap so the plan sums to `Importe pendiente`. Per-account replace, only when at least one future row exists. |

`credit_plan_closed_f`, `open_debit_f` and `open_credit_f` stay for history but are no longer written. `reload_open_movements`, `replace_open_account_movements` and `truncate_open_movements` are dropped. Apply 011 on Neon by hand after 008, 009 and 010.

`row_hash` (sql/014, see [docs/row_hash.md](docs/row_hash.md)) is the sha256 of `user_id|account_id|bank_id|txn_date|concept_sk|abonos|cargos|occurrence`. The occurrence counter numbers identical same-day rows. Balance, period, file and names are not in the hash. All five masters use the column names `abonos` and `cargos`. The credit and future tables were renamed from `abono`/`cargo` in 014. Signs: debit `cargos <= 0`, `abonos >= 0`; credit `cargos >= 0`, `abonos >= 0`, so a card payment (debit -X, credit abono +X) balances. `concept_sk` is the digits in the trimmed concept, or the letters when there are no digits. Debit amount is `abonos + cargos`. Since sql/018, credit and installment amount is `abonos - cargos` (a purchase is negative) with `cargos` = `mensualidad` on a future row; the future payment date is in the hash, so each month of a plan is its own row. A second file that repeats a hash is rejected as already uploaded, and the whole load rolls back.

### Change a credit card's cutoff day (sql/012)

Credit card accounts show **Change cutoff day** on their card (cutoff day 1-31, payment window 1-90 days). Debit and savings accounts do not have it, and the API rejects it for them. The page calls `POST /accounts/{accountId}/cutoff`, which runs `update_bank_account_cutoff(account, cutoff_day, credit_days, as_of)` under the same tenant and user session as the other statement functions.

- A period with any uploaded file (statement, installment or PDF, closed or open) keeps its `period_start`, `period_end` and `cutoff_date`. `refresh_statement_periods` no longer rewrites a loaded period.
- Empty periods are planned again on the new day. The current period moves to the new day when it has no file. When the current period already has an open statement, it stays current with its dates, and the new day starts with the next period (for example, Nov 7 - Dec 6 loaded, new day 20: the next period is Dec 7 - Jan 20).
- Periods never overlap and leave no gap: an empty period between loaded periods runs from the day after one to the day before the next.
- Future MSI rows due after the as-of date move to the next cutoff dates on the new day, keeping the same number of remaining payments per plan. Their `row_hash` is recomputed with the new date.
- Changing only the payment window does not touch any period.

Apply 012 on Neon by hand after 011. The Lambda route needs an AWS deploy before the deployed page can save the change.

### File names and vault keys (sql/013)

- **Chosen name.** The page sends `chosen_filename` = the exact `file.name` the user picked, and ingest stores it in `statement_uploads_f.chosen_filename` (trimmed, control characters dropped). The page shows that name. `original_filename` keeps its old meaning: the working CSV name. The page shows it as "saved as ..." when it differs. Rows loaded before 013 get `chosen_filename = original_filename` with `chosen_filename_source = 'legacy'`.
- **Vault names.** Premium vault copies are written once (Object Lock governance, 365 days) as `curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{csv|pdf}`:
  - `YYYY-MM` is the `period_end` of the upload's period (a credit card period Sep 7 - Oct 6 is `2026-10`).
  - `account` is `bank_accounts_d.account_number`, the number the page shows next to the account name. `Bank` is the bank name. Both use the `strmStoredUploadFilename` rule (characters outside `A-Za-z0-9_.-` become `_`).
  - `_msi` marks the installment (MSI) file. The statement CSV and the PDF share the base name and differ by extension.
  - `_vN` (N = 2, 3, ...) is added when the name was already used. The vault is write-once, so a replaced open-period file, a re-upload after a delete, or a closed statement that replaces a stale open file gets the next version. `curated_vault_keys_d` records every name handed out and keeps it after the upload is deleted, so a name is never reused.
  - SQL `curated_standard_key` / `reserve_vault_key` are the definition. `apps/statements/curated.py` `standard_object_key` mirrors it and is tested against it.
- **Self-describing vault.** Each object carries S3 metadata (`x-amz-meta-original-filename`, `bank`, `account`, `period`, `period-start`, `period-end`, `dataset`, `upload-id`, `content-sha256`, `object-sha256`; values are percent-encoded UTF-8, the file name cut to 120 characters). Next to it the Lambda writes `curated/{tenant}/manifest/{object file name}.json`, also write-once, with the bank, account (number, name, type, cutoff day, payment window), period (start, end, cutoff date), dataset, slot, ledger state, chosen and stored names, upload id, row count and SHA-256. Deleting a file in the app keeps the vault object and writes `.../manifest/{object file name}.deleted.json`. To rebuild from the bucket alone, read every `manifest/*.json`, drop the ones that have a `.deleted.json`, keep the highest `_vN` per `{YYYY-MM}_{account}_{Bank}[_msi]` and extension, and load each object through ingest for its account and period.
- **Objects already in the vault are not renamed automatically.** `uv run python scripts/curated_key_migration.py` (owner `DATABASE_URL`) is a dry run. For every upload that has `curated_s3_key` it prints the current key, the backup key `curated/backup-{batch}/{tenant}/{upload_id}.{ext}`, the new name and the manifest key. With `--apply --bucket B --confirm-bucket B` it reserves the name, copies the object to the backup key and to the new name (with the vault metadata), checks both copies, writes the manifest and records the change (`curated_legacy_s3_key`, `curated_backup_s3_key`). The original object is never deleted. Rows without a vault key are database-only and are skipped. Vault objects whose upload was deleted have no row, so the script cannot name them.

Apply 013 on Neon by hand after 011 and 012, before deploying the Lambda that calls `ingest_statement_upload` / `ingest_period_pdf_upload`.

### What the Banorte samples showed

| File | Shape | Encoding and quirks |
| --- | --- | --- |
| Debit export | `Fecha, Concepto, Cargos, Abonos, Saldos` | UTF-8, LF, comma. Charges are already negative, deposits positive, and the other side is `0.0`. One concept is a long SPEI line. No non-breaking space in this file. 11 movements. |
| Credit statement | `Fecha, Concepto, Abono, Cargo, Tarjeta` | UTF-8, CRLF, comma. `Tarjeta` looks like `Titular ***3978`. Two Microsoft rows are identical, so the occurrence counter is required. 31 movements. |
| Installment export | `Fecha de operación, Tasa anual, Importe inicial, Importe pendiente, Concepto, Pagos pendientes, Mensualidad` | Windows-1252 (`ó` is byte `0xF3`), CRLF. `Tasa anual` is `0.0000%`. `Pagos pendientes` is the text ` 03/03`, not a number. 1 movement. |

The loader lowercases headers, strips accents, and accepts either line ending. The browser tries UTF-8 and falls back to Windows-1252, then folds non-breaking spaces to spaces. The lineage concepts end in a non-breaking space; these three samples do not.

### Supported banks and statement profiles

Statement ingestion maps bank-specific CSV exports into a common canonical schema:

| Profile code | Bank | Dataset | Header / Shape | Amount convention | Encoding |
| --- | --- | --- | --- | --- | --- |
| `banorte_debit_v1` | Banorte | debit | `Fecha, Concepto, Cargos, Abonos, Saldos` | Cargos negative, Abonos positive, Saldos balance | UTF-8 / Windows-1252 |
| `banorte_credit_monthly_v1` | Banorte | credit_monthly | `Fecha, Concepto, Abono, Cargo, Tarjeta` | Both positive (stored as credit `cargos`/`abonos`, both >= 0) | UTF-8 |
| `banorte_credit_plan_v1` | Banorte | credit_plan | `Fecha de operación, Tasa anual, Importe inicial, Importe pendiente, Concepto, Pagos pendientes, Mensualidad` | Mensualidad positive, parses "03/12" as 3 payments still due out of 12 | Windows-1252 |
| `hsbc_debit_v1` | HSBC | debit | Headerless, 3 columns (`date, description, signed amount`) | Signed amount (e.g. `"-21,878.96"`), quoted thousands comma, Saldos NULL | UTF-8 |
| `bbva_*` | BBVA | debit / credit | BBVA-ready (add registry row when sample arrives) | TBD | TBD |

#### How to add a bank or profile

1. Insert a row into `public.file_profiles_d` (and mirror in `PROFILES` in `apps/statements/profiles.py`):
   - Set `profile_code`, `bank_name`, `dataset` (`debit`, `credit_monthly`, `credit_plan`).
   - If the file has headers: set `has_header = TRUE`, `header_signature = ARRAY['sorted', 'normalized', 'headers']`.
   - If headerless: set `has_header = FALSE`, `header_signature = NULL`, and `column_count`.
   - Specify `amount_rule` (`split_signed`, `split_positive_credit`, `single_signed`, `installment`).
2. Add a synthetic, anonymized test fixture in `apps/statements/tests/fixtures/`.
3. Add a test in `apps/statements/tests/test_profiles.py`.
4. Ensure the bank exists in `public.banks_d`. No code change is required unless a new amount rule is needed.

### Apply it from the config console

From the repository root, with the Neon URL saved:

```bash
uv run streamlit run apps/config_console/app.py
```

1. **Apply users DDL** if `cognito_users.users` is not there yet.
2. **Apply banking DDL**. This runs `sql/004_public_banking.sql` only when `public.bank_accounts_d` is missing, then `sql/006_statement_flow.sql`. It does not deploy AWS. Repeating it keeps uploaded files and resets the plan caps.
3. **Deploy AWS objects** when you want the statements API and the curated bucket. That deploy was not run for this change. The curated bucket is versioned, locked in governance mode for 365 days, and its `curated/*` keys deny delete. It is retained if the stack is destroyed. An account admin can replace the bucket policy; the application role cannot delete the objects.

Publish the site after the API exists so `config.js` receives `apiUrl`. Admins open **Statements** from the page list. Other signed-in users land on the statements page directly.

### UAT checklist

1. Apply users DDL, then banking DDL, against the Neon database. Do not expect AWS resources until **Deploy AWS objects**.
2. Sign in. Open Banorte debit `0639` with no cutoff, and credit `3978` with cutoff day 6 and a 20-day payment window. Confirm the account number still shows `0639`.
3. On a date of 2026-10-20 (or any later October date before the 31st), debit periods are 2026-07 through 2026-09 and credit periods are 2026-08 through 2026-10. October debit has no slot. The credit card shows cutoff day 6 and a 20-day payment window. October starts 2026-09-07 and its cutoff is 2026-10-06. The statements API also returns `payment_due` as that cutoff plus 20 days (2026-10-26).
4. Drop the debit sample on a debit period, the credit statement sample on a credit statement slot, and the installment sample on the installment slot. All three load. The two identical Microsoft rows both appear.
5. Drop the same debit file again. The page says `already uploaded` and no extra rows appear.
6. Delete the file. Every row from that file disappears, the period is pending again, and a dimension row for the hash remains.
7. Add the previous period, then remove it while it is empty. A period that has a file, or one of the three current periods, cannot be removed.
8. On Free, a second debit or a second credit is rejected. On Premium, the 11th account is rejected with the private-deployment message.
9. Premium shows an optional PDF slot. Free does not. Deleting a file does not delete `curated/...` in S3.

### Assumptions

- Comma-separated CSV. Dates are `DD/MM/YYYY` or `YYYY-MM-DD`. Header check is the whole header set after folding case and accents, not a single-column map. Signs are stored as exported. Zeros stay zeros. `Pagos pendientes` stays text.
- The installment file is its own slot. It does not clear the statement pending flag. The optional PDF is the same: tracked on the period, not inserted as master rows.
- "Past the cutoff" means the date is strictly after `period_end`. February 31 clamps to the last day of February.
- Savings uses the debit file, the month-end close, and the free plan's debit slot.
- Open and future replaces are per account (and tenant/user) inside `ingest_statement_csv`; no table is ever truncated.
- Re-applying the statement SQL resets plan caps. The first apply replaces an older statement-table shape that has no `row_hash`. Later applies keep files.
- The statements API reads and writes `cognito_users.users`, matching `sql/004_public_banking.sql`.
- More than 10 accounts is a private deployment of this repository in the client's own AWS account and Neon project, from the config console. There is no wizard for that.

## Repo layout

```
apps/config_console/   Streamlit operator UI
infra/                 CDK (control + per-environment + login Lambda)
sql/                   001–002 login, 004 banking model, 006 statement flow
web/                   Cognito login page (local config.js is gitignored)
scripts/cdk-bootstrap.sh
config/                Example config (no real secrets)
```

Tests: `uv run pytest` from the repository root.

## Dimensions, API tokens and the Google Sheets API (sql/015)

- **Dimensions page**: label each movement with `attribute_1..3` (`debit_d`, `credit_d`,
  keyed by `row_hash`); see `docs/dimensions.md`.
- **GraphQL API** (`POST {api-url}/graphql`) for Google Sheets with per-user read-only
  tokens, per-plan quotas in `plans_d` (`api_calls_limit` per `api_window`: Free 1/week,
  Premium 3/day; Entry and Plus are placeholders to confirm), a call log
  (`api_usage_f`), HTTP 429 over quota, and request/row limits; see `docs/graphql.md`.
  Apps Script: `integrations/google_sheets/Code.gs` (one call per "Refresh all").
- Deploy: apply `sql/015_dimensions_api.sql` on Neon after 014, then `npm ci` in `infra`
  (new dependency `graphql`) and deploy the environment stack (new `GraphqlApi` Lambda,
  `POST /graphql` route with throttling, `/dimensions` and `/api-tokens` routes), then
  publish the site (`web/dimensions.js`).

## Lists, transfers and upload completeness (sql/016)

- **Lists**: bind `attribute_1..3` to a list (`list_f`, `list_d`, `attribute_settings_d`);
  movements store the item id, readers get the item name. Lists page + pickers in the
  Dimensions editor. See `docs/dimensions.md`.
- **Transfers** between your accounts (`inter_accounts_d`): auto-detected (same date, same
  amount, opposite direction; same bank first, then across banks; card payments count),
  created flagged `auto` for review, linkable/unlinkable by hand; GraphQL gets
  `is_internal_transfer` and `excludeTransfers`. See `docs/transfers.md`.
- **Upload completeness** on the Statements page (open period + two closed periods per
  account). See `docs/dimensions.md`.
- Deploy: apply `sql/016_lists_completeness_transfers.sql` on Neon after 015, deploy the
  environment stack (new `/lists`, `/list-items`, `/attribute-settings`, `/transfers`
  routes; GraphQL Lambda with the new fields), publish the site, and paste the new
  `integrations/google_sheets/Code.gs` (optional `exclude_transfers` config column).

## Investments & Assets (sql/017)

- Savings, Investment, Asset and Credit contract accounts (Infonavit, Afore, CETES, GBM,
  cash, a car, a credit contract) at a bank or an institution, with their own plan limit.
  Closed periods stay in `master_closed_aaccandass_f`; the current period is
  `master_open_aaccandass_f` (sql/019). Abonos = in/gain, cargos = out/loss, both positive.
  Labels for both tables live in `master_closed_aaccandass_d`.
- Upload any CSV/XLSX with a column map (concept can join columns with `||`), preview, save
  the map as a template per account; add PDF-only movements by hand; type the real balance
  at a date and the difference becomes one adjustment row. Balance at any date and month
  ends. Page **Investments & Assets**; GraphQL `kind: ASSET`; sixth Sheets tab.
  See `docs/investments_assets.md`.
- Deploy: apply `sql/017_investments_assets.sql` on Neon after 016, deploy the environment
  stack (`/assets…` routes), publish the site, paste the new `Code.gs`.

## Standard masters, balances and banks (sql/018)

The master tables share one layout (`master_open_aaccandass_f` added in sql/019): `row_id | file_id, tenant_id, user_id, account_id,
bank_id, cutoff_id | txn_date, concept, abonos, cargos | amount, concept_sk, row_hash`.
Debit `cargos` stay negative (`amount = abonos + cargos`). Credit and asset `cargos` stay
positive (`amount = abonos - cargos`). `file_name` and `source_profile` come from the upload.
`saldos` and `tarjeta` are not stored. See `docs/standard_masters.md`.

Every account can now have:

* an opening balance (Saldo inicial);
* a monthly check, which adds one adjustment row;
* a move to another bank. Its attributes, lists and transfer links follow it.

Users can add and rename banks on the Statements page. A file with an unknown layout opens
a column map that is saved per account (the sql/017 map table). The "Data admin" page and
the `/admin` Lambda are gone. `sql/018b_drop_unused.sql` drops the unused tables, including
`bank_templates_f`; it runs separately, after you confirm its list. `credit_plan_closed_f`
stays.

