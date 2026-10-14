from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qsl, quote, urlencode, urlparse, urlunparse

ENV_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,20}$")
SCHEMA_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PROJECT = "strm_bank"


@dataclass(frozen=True)
class EnvVarSpec:
    key: str
    label: str
    description: str
    secret: bool = False
    default: str = ""


# Same keys for every environment. This list is the runbook.
ENV_VARS: tuple[EnvVarSpec, ...] = (
    EnvVarSpec(
        key="aws_region",
        label="AWS region",
        description="Region where this environment's site and data buckets are deployed.",
        default="us-east-1",
    ),
    EnvVarSpec(
        key="aws_object_prefix",
        label="AWS object prefix",
        description="Tag and SSM prefix for every object in this environment (example: strm_bank_dev).",
    ),
    EnvVarSpec(
        key="neon_database_url",
        label="Neon database URL",
        description=(
            "Paste the Neon URI as-is. Example: "
            "postgresql://neondb_owner:PASSWORD@ep-xxx.neon.tech/neondb?sslmode=require. "
            "The password is the part between the colon after the user and the @."
        ),
    ),
    EnvVarSpec(
        key="neon_user",
        label="Neon user",
        description="Filled from the URL when you save. Neon default is often neondb_owner.",
        default="neondb_owner",
    ),
    EnvVarSpec(
        key="neon_database",
        label="Neon database",
        description="Postgres database name inside the project. Neon default is neondb. Used as {{NEON_DATABASE}} in sql/.",
        default="neondb",
    ),
    EnvVarSpec(
        key="neon_users_schema",
        label="Cognito users schema",
        description=(
            "Schema that stores cognito_users.users (user_id linked to Cognito sub). "
            "Default cognito_users. Used as {{NEON_USERS_SCHEMA}} in sql/."
        ),
        default="cognito_users",
    ),
    EnvVarSpec(
        key="neon_db_schema",
        label="App core schema",
        description="Stored for the next step (app model + per-user views). Not applied yet.",
        default="core",
    ),
    EnvVarSpec(
        key="snowflake_account",
        label="Snowflake account",
        description="Optional warehouse account for Plus/Premium sync. Empty until that pipe exists.",
    ),
)


def validate_environment_name(name: str) -> str:
    candidate = name.strip()
    if not ENV_NAME_RE.match(candidate):
        raise ValueError(
            "Environment name must be lowercase, start with a letter, "
            "and use only letters, digits, or underscore (max 21 chars).",
        )
    return candidate


def validate_schema_name(name: str) -> str:
    candidate = name.strip() or "core"
    if not SCHEMA_RE.match(candidate) or candidate.lower() in {"pg_catalog", "information_schema"}:
        raise ValueError(f"Invalid PostgreSQL schema name '{name}'")
    return candidate


def object_prefix(environment_name: str) -> str:
    return f"{PROJECT}_{validate_environment_name(environment_name)}"


def compose_database_url(
    *,
    host: str,
    user: str,
    password: str,
    database: str,
    sslmode: str = "require",
) -> str:
    if not host or not user or not database:
        raise ValueError("Host, user, and database are required to compose a URL")
    netloc = f"{quote(user, safe='')}:{quote(password, safe='')}@{host}"
    return urlunparse(("postgresql", netloc, f"/{database.lstrip('/')}", "", f"sslmode={sslmode}", ""))


def default_values(environment_name: str) -> dict[str, str]:
    name = validate_environment_name(environment_name)
    values = {spec.key: spec.default for spec in ENV_VARS}
    values["aws_object_prefix"] = object_prefix(name)
    values["neon_database"] = values.get("neon_database") or "neondb"
    values["neon_users_schema"] = values.get("neon_users_schema") or "cognito_users"
    values["neon_db_schema"] = values.get("neon_db_schema") or "core"
    return values


def merge_config(environment_name: str, stored: dict[str, Any] | None) -> dict[str, str]:
    merged = default_values(environment_name)
    if stored:
        for spec in ENV_VARS:
            if spec.key in stored and stored[spec.key] is not None:
                merged[spec.key] = str(stored[spec.key])
    if stored and stored.get("aws_object_prefix"):
        merged["aws_object_prefix"] = str(stored["aws_object_prefix"])
    else:
        merged["aws_object_prefix"] = object_prefix(environment_name)
    return merged


def neon_user_from_url(url: str) -> str:
    if not url:
        return ""
    return urlparse(url).username or ""


def neon_database_from_url(url: str) -> str:
    if not url:
        return "neondb"
    path = urlparse(url).path.lstrip("/")
    return path.split("/")[0] if path else "neondb"


def connectable_url(url: str) -> str:
    """Keep sslmode=require. Drop channel_binding so psycopg does not need extra SCRAM options."""
    parsed = urlparse(url)
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query.pop("channel_binding", None)
    query.setdefault("sslmode", "require")
    return urlunparse(parsed._replace(query=urlencode(query)))


def render_sql(
    sql_text: str,
    *,
    app_schema: str,
    users_schema: str,
    database: str,
) -> str:
    return (
        sql_text.replace("{{NEON_DB_SCHEMA}}", app_schema)
        .replace("{{NEON_USERS_SCHEMA}}", users_schema)
        .replace("{{NEON_DATABASE}}", database)
    )
