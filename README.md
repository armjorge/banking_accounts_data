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

## Recreating on a new laptop

1. `aws login` and `aws sts get-caller-identity`
2. Clone the repo, `uv sync`, `uv run streamlit run apps/config_console/app.py`
3. Config is already in the control-plane S3 bucket. No `.env` to copy.
4. Bootstrap CDK only if this account/region has never been bootstrapped.

## Product tiers (later)

| Plan | Data | API |
| --- | --- | --- |
| Entry | Local app data, bank templates | None |
| Plus | Cloud Postgres + Snowflake backup | Metered |
| Premium | Same | Higher quota |

## Repo layout

```
apps/config_console/   Streamlit operator UI
infra/                 CDK (control + per-environment + login Lambda)
sql/                   001–002 login DDL now; 003–004 app model later
web/                   Cognito login + welcome page
scripts/cdk-bootstrap.sh
config/                Example config (no real secrets)
```

Tests: `uv run pytest` from the repository root.
