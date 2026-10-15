from __future__ import annotations

import os
import sys
from pathlib import Path

import streamlit as st
from botocore.exceptions import BotoCoreError, ClientError

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from aws_env import (
    caller_identity,
    control_config_bucket,
    list_admin_users,
    list_tagged_resources,
    load_prefix_params,
)
from catalog import (
    ENV_VARS,
    compose_database_url,
    default_values,
    neon_database_from_url,
    neon_user_from_url,
    object_prefix,
    validate_environment_name,
)
from deploy import deploy_environment
from env_store import list_environments, load_environment, save_environment, save_infra_outputs
from bootstrap_env import bootstrap_environment
from postgres_ops import apply_users_ddl, list_tables, ping
from site_publish import publish_frontend


def _live_log():
    box = st.empty()
    chunks: list[str] = []

    def on_line(line: str) -> None:
        chunks.append(line)
        box.code("".join(chunks[-120:]))

    return on_line

st.set_page_config(page_title="Strm Bank control", layout="wide")
st.title("Strm Bank control plane")
st.caption(
    "This page deploys AWS for a named environment (config bucket, site bucket, data bucket). "
    "CDK bootstrap is separate and already done: it only prepares account 747289880051 in us-east-1 "
    "so CloudFormation can run. It is not the product stack."
)

with st.sidebar:
    st.header("AWS session")
    region = st.text_input(
        "AWS region",
        value=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1",
    )
    st.markdown(
        "Credentials come from this machine's AWS CLI (`aws login` in any terminal is enough). "
        "Python needs `uv sync` so `botocore[crt]` can read that login. "
        "Attach `StrmBank-Control-Operator` after the control stack exists."
    )

identity = None
identity_error = None
try:
    identity = caller_identity(region)
except (BotoCoreError, ClientError, Exception) as exc:  # noqa: BLE001
    identity_error = str(exc)

if identity:
    st.sidebar.success(identity.arn)
else:
    st.sidebar.warning("No AWS credentials in this shell.")
    if identity_error:
        st.sidebar.code(identity_error)

bucket = None
bucket_error = None
if identity:
    try:
        bucket = control_config_bucket(region)
    except Exception as exc:  # noqa: BLE001
        bucket_error = str(exc)

if bucket:
    st.info(f"Shared config bucket is ready: `{bucket}`")
else:
    st.info(
        "No config bucket yet. Type an environment name below and deploy. "
        "That call creates the shared config bucket and that environment's site + data buckets."
    )
    if bucket_error and "Control plane not found" not in bucket_error:
        st.warning(bucket_error)

environments: list[str] = []
if bucket:
    try:
        environments = list_environments(bucket, region)
    except Exception as exc:  # noqa: BLE001
        st.error(str(exc))

st.subheader("Create or deploy an environment")
new_name = st.text_input(
    "Environment name",
    placeholder="dev",
    help="Lowercase, start with a letter. Example: dev, prd, staging.",
)
prefix_preview = None
try:
    if new_name.strip():
        prefix_preview = object_prefix(validate_environment_name(new_name))
except ValueError as exc:
    st.error(str(exc))

if prefix_preview:
    st.write(
        f"Will tag AWS objects with `EnvPrefix={prefix_preview}` and deploy stacks "
        f"`StrmBank-Control` + `StrmBank-{validate_environment_name(new_name)}`."
    )

account_id = identity.account if identity else None
can_deploy = bool(identity and new_name.strip() and prefix_preview)
if st.button("Create environment and deploy AWS objects", type="primary", disabled=not can_deploy):
    try:
        name = validate_environment_name(new_name)
        prefix = object_prefix(name)
        st.caption(
            "CloudFront often takes 5–10 minutes. CDK lines should appear below and in this terminal."
        )
        on_line = _live_log()
        code, log, outputs = deploy_environment(
            name,
            prefix,
            account=account_id,
            region=region,
            on_line=on_line,
        )
        if code != 0:
            st.error("CDK deploy failed.")
            st.code(log)
        else:
            resolved_bucket = control_config_bucket(region)
            save_environment(resolved_bucket, region, name, default_values(name))
            save_infra_outputs(resolved_bucket, region, name, outputs)
            st.session_state.selected_env = name
            st.success(f"Environment `{name}` is deployed. Prefix `{prefix}`.")
            st.json(outputs)
            st.rerun()
    except Exception as exc:  # noqa: BLE001
        st.error(str(exc))

if environments:
    selected = st.selectbox(
        "Active environment",
        environments,
        index=environments.index(st.session_state["selected_env"])
        if st.session_state.get("selected_env") in environments
        else 0,
    )
else:
    selected = None
    st.caption("After the first deploy, environments appear here so you can edit variables and redeploy.")

if not (bucket and selected):
    st.stop()

st.session_state.selected_env = selected
document = load_environment(bucket, region, selected)
values = document["values"]
prefix = values.get("aws_object_prefix") or object_prefix(selected)

st.markdown(f"**Prefix:** `{prefix}` · last saved `{document.get('updated_at') or 'never'}`")

st.subheader("3. Environment variables")
st.write("The same keys exist for every environment. Descriptions stay here so you do not hunt the laptop later.")

edited = dict(values)
neon_keys = {
    "neon_database_url",
    "neon_user",
    "neon_database",
    "neon_users_schema",
    "neon_db_schema",
}
for spec in ENV_VARS:
    if spec.key in neon_keys:
        continue
    edited[spec.key] = st.text_input(
        spec.label,
        value=edited.get(spec.key, spec.default),
        help=spec.description,
        key=f"{selected}_{spec.key}",
    )

st.subheader("Neon")
st.markdown(
    "Paste the **full** Neon URI. It is shown in clear text so you can see user, host, and database. "
    "The password is the segment between `:` and `@`."
)
st.code(
    "postgresql://neondb_owner:YOUR_PASSWORD@ep-....neon.tech/neondb?sslmode=require",
    language="text",
)
edited["neon_database_url"] = st.text_area(
    "Neon database URL",
    value=edited.get("neon_database_url", ""),
    height=80,
    help="Copy from the Neon console. channel_binding=require is stripped at connect time.",
    key=f"{selected}_neon_database_url",
)
if edited.get("neon_database_url"):
    edited["neon_user"] = neon_user_from_url(edited["neon_database_url"]) or edited.get("neon_user", "")
    edited["neon_database"] = neon_database_from_url(edited["neon_database_url"]) or edited.get(
        "neon_database",
        "neondb",
    )

n1, n2 = st.columns(2)
with n1:
    edited["neon_user"] = st.text_input(
        "Neon user",
        value=edited.get("neon_user") or "neondb_owner",
        key=f"{selected}_neon_user",
    )
with n2:
    edited["neon_database"] = st.text_input(
        "Database (default neondb)",
        value=edited.get("neon_database") or "neondb",
        key=f"{selected}_neon_database",
    )
edited["neon_users_schema"] = st.text_input(
    "Cognito users schema (default cognito_users)",
    value=edited.get("neon_users_schema") or "cognito_users",
    help="Only this schema is applied now: users.user_id linked to Cognito sub.",
    key=f"{selected}_neon_users_schema",
)
edited["neon_db_schema"] = edited.get("neon_db_schema") or "core"

with st.expander("Or compose the URL from parts"):
    host = st.text_input("Host", placeholder="ep-royal-meadow-....neon.tech", key=f"{selected}_host")
    password = st.text_input("Password only", type="password", key=f"{selected}_password")
    if st.button("Compose URL"):
        try:
            url = compose_database_url(
                host=host,
                user=edited["neon_user"] or "neondb_owner",
                password=password,
                database=edited["neon_database"] or "neondb",
            )
            st.session_state[f"{selected}_neon_database_url"] = url
            save_environment(bucket, region, selected, {**edited, "neon_database_url": url})
            st.rerun()
        except Exception as exc:  # noqa: BLE001
            st.error(str(exc))

if st.button("Save variables to config bucket", type="primary"):
    try:
        save_environment(bucket, region, selected, edited)
        st.success(f"Saved {selected} to s3://{bucket}/environments/{selected}/config.json")
        st.rerun()
    except Exception as exc:  # noqa: BLE001
        st.error(str(exc))

st.subheader("4. Deploy this environment")
st.write(
    "Creates the static-site bucket, the app-data bucket, CloudFront, and Cognito, "
    f"all tagged `Project=strm_bank` and `EnvPrefix={prefix}`."
)
protected = selected in {"prod", "prd", "production"}
confirm = True
if protected:
    confirm = st.checkbox(f"I understand this deploys {selected}")
if st.button(f"Deploy AWS objects for {selected}", disabled=not confirm):
    st.caption("CDK events stream below. CloudFront is the slow step.")
    on_line = _live_log()
    code, log, outputs = deploy_environment(
        selected,
        prefix,
        account=identity.account if identity else None,
        region=region,
        on_line=on_line,
    )
    if code == 0:
        save_infra_outputs(bucket, region, selected, outputs)
        st.success("Environment stack deployed. Outputs stored next to the variables.")
        st.json(outputs)
    else:
        st.error("Environment deploy failed.")
        st.code(log)

infra = {**load_prefix_params(prefix, region), **(document.get("infra_outputs") or {})}
if infra:
    st.write("Deployed outputs")
    st.json(infra)

st.subheader("5. Tagged objects")
if st.button("Refresh inventory"):
    st.session_state.inventory = list_tagged_resources(region, prefix)
inventory = st.session_state.get("inventory")
if inventory:
    st.table(inventory)
elif inventory == []:
    st.write("No tagged resources yet. Deploy this environment first.")

st.subheader("6. Login database")
url = edited.get("neon_database_url", "")
users_schema = edited.get("neon_users_schema") or "cognito_users"
database = edited.get("neon_database") or "neondb"
st.caption(
    f"This step only creates `{database}.{users_schema}.users` "
    "(user_id + cognito_sub). App core DDL comes later."
)
db_cols = st.columns(2)
with db_cols[0]:
    if st.button("Test Neon connection", disabled=not url):
        try:
            info = ping(url, users_schema)
            st.success(f"Connected to `{info['database']}` as `{info['user']}`.")
            st.write(list_tables(url, users_schema) or f"(no tables in {users_schema})")
        except Exception as exc:  # noqa: BLE001
            st.error(str(exc))
with db_cols[1]:
    if st.button("Apply users DDL", disabled=not url):
        try:
            applied = apply_users_ddl(
                url,
                users_schema=users_schema,
                database=database,
            )
            st.success("Applied: " + ", ".join(applied))
            st.write(list_tables(url, users_schema))
        except Exception as exc:  # noqa: BLE001
            st.error(str(exc))

st.subheader("7. Login site")
st.write(
    "Publish replaces the files in this environment's website bucket and refreshes CloudFront. "
    "Signed-in users land on the welcome page."
)
st.info(
    "To access the admin console, the email must be part of the Cognito group `admin`. "
    "Add or remove people in the Cognito user pool, then sign in again."
)
pool_id = infra.get("user-pool-id")
if pool_id:
    try:
        admin_emails = list_admin_users(region, pool_id)
    except Exception as exc:  # noqa: BLE001
        admin_emails = None
        st.warning(str(exc))
    if admin_emails:
        st.dataframe(
            {"email": admin_emails},
            hide_index=True,
            alt="Emails in the Cognito admin group",
        )
    elif admin_emails == []:
        st.caption("The admin group has no users yet.")
else:
    st.caption("Deploy this environment to see the admin group.")
ready = bool(url and infra.get("website-bucket") and infra.get("user-pool-client-id"))
boot_col, pub_col = st.columns(2)
with boot_col:
    if st.button("Bootstrap users table + login site", type="primary", disabled=not ready):
        try:
            result = bootstrap_environment(
                neon_url=url,
                users_schema=users_schema,
                database=database,
                outputs=infra,
                region=region,
            )
            st.success(result["schema"])
            st.markdown(f"Open [{result['webUrl']}]({result['webUrl']})")
            st.json(result)
        except Exception as exc:  # noqa: BLE001
            st.error(str(exc))
with pub_col:
    if st.button("Publish frontend only", disabled=not bool(infra.get("website-bucket"))):
        try:
            published = publish_frontend(infra, region)
            st.success(f"Published {published['uploaded']}")
            st.markdown(f"Open [{published['webUrl']}]({published['webUrl']})")
        except Exception as exc:  # noqa: BLE001
            st.error(str(exc))
