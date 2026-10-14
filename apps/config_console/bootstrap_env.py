from __future__ import annotations

from aws_env import publish_neon_runtime_params
from postgres_ops import apply_users_ddl, list_tables
from site_publish import publish_frontend


def _has_users_table(url: str, users_schema: str) -> bool:
    tables = list_tables(url, users_schema)
    return any(name.endswith(".users") for name in tables)


def bootstrap_environment(
    *,
    neon_url: str,
    users_schema: str,
    database: str,
    outputs: dict[str, str],
    region: str,
) -> dict[str, str]:
    notes: list[str] = []
    if not _has_users_table(neon_url, users_schema):
        applied = apply_users_ddl(
            neon_url,
            users_schema=users_schema,
            database=database,
        )
        notes.append("Applied login DDL: " + ", ".join(applied))
    else:
        notes.append(f"Schema `{users_schema}` already has `users`.")
    publish_neon_runtime_params(
        region,
        outputs["prefix"],
        {
            "neon_database_url": neon_url,
            "neon_users_schema": users_schema,
        },
    )
    published = publish_frontend(outputs, region)
    notes.append(f"Published login site to {published['webUrl']}")
    return {**published, "schema": "; ".join(notes)}
