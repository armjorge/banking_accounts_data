from __future__ import annotations

from pathlib import Path

import psycopg

from catalog import connectable_url, render_sql, validate_schema_name

REPO_ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = REPO_ROOT / "sql"


def ping(url: str, schema: str | None = None) -> dict[str, str]:
    with psycopg.connect(connectable_url(url), connect_timeout=8) as conn:
        if schema:
            qualified = validate_schema_name(schema)
            conn.execute(f'CREATE SCHEMA IF NOT EXISTS "{qualified}"')
            conn.execute(f'SET search_path TO "{qualified}", public')
        with conn.cursor() as cur:
            cur.execute("SELECT current_database(), current_user, current_schema(), version()")
            database, user, current_schema, version = cur.fetchone()
    return {
        "database": database,
        "user": user,
        "schema": current_schema,
        "version": version,
    }


def list_tables(url: str, schema: str | None = None) -> list[str]:
    query = """
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY 1
    """
    params: tuple[str, ...] = ()
    if schema:
        query = """
            SELECT table_schema || '.' || table_name
            FROM information_schema.tables
            WHERE table_schema = %s
            ORDER BY 1
        """
        params = (validate_schema_name(schema),)
    with psycopg.connect(connectable_url(url), connect_timeout=8) as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            return [row[0] for row in cur.fetchall()]


def _statements(sql_text: str) -> list[str]:
    return [part.strip() for part in sql_text.split(";") if part.strip()]


USER_DDL_FILES = ("001_extensions.sql", "002_cognito_users.sql")


def apply_users_ddl(
    url: str,
    *,
    users_schema: str,
    database: str = "neondb",
) -> list[str]:
    users = validate_schema_name(users_schema)
    applied: list[str] = []
    with psycopg.connect(connectable_url(url), connect_timeout=8) as conn:
        try:
            conn.execute(f'CREATE SCHEMA IF NOT EXISTS "{users}"')
            conn.execute(f'SET search_path TO "{users}", public')
            for name in USER_DDL_FILES:
                sql_file = SQL_DIR / name
                rendered = render_sql(
                    sql_file.read_text(encoding="utf-8"),
                    app_schema="core",
                    users_schema=users,
                    database=database,
                )
                for statement in _statements(rendered):
                    conn.execute(statement)
                applied.append(sql_file.name)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return applied
