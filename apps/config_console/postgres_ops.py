from __future__ import annotations

import re
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


def split_sql(sql_text: str) -> list[str]:
    """Split a script on semicolons that are not inside quotes, comments, or dollar bodies."""
    statements: list[str] = []
    buffer: list[str] = []
    index = 0
    length = len(sql_text)
    dollar_tag: str | None = None
    in_single = False
    in_line_comment = False
    in_block_comment = False
    while index < length:
        char = sql_text[index]
        nxt = sql_text[index + 1] if index + 1 < length else ""
        if in_line_comment:
            buffer.append(char)
            index += 1
            if char == "\n":
                in_line_comment = False
            continue
        if in_block_comment:
            buffer.append(char)
            if char == "*" and nxt == "/":
                buffer.append(nxt)
                index += 2
                in_block_comment = False
                continue
            index += 1
            continue
        if dollar_tag is not None:
            if sql_text.startswith(dollar_tag, index):
                buffer.append(dollar_tag)
                index += len(dollar_tag)
                dollar_tag = None
                continue
            buffer.append(char)
            index += 1
            continue
        if in_single:
            buffer.append(char)
            if char == "'" and nxt == "'":
                buffer.append(nxt)
                index += 2
                continue
            if char == "'":
                in_single = False
            index += 1
            continue
        if char == "-" and nxt == "-":
            buffer.append("--")
            index += 2
            in_line_comment = True
            continue
        if char == "/" and nxt == "*":
            buffer.append("/*")
            index += 2
            in_block_comment = True
            continue
        if char == "'":
            in_single = True
            buffer.append(char)
            index += 1
            continue
        if char == "$":
            match = re.match(r"\$[A-Za-z0-9_]*\$", sql_text[index:])
            if match:
                dollar_tag = match.group(0)
                buffer.append(dollar_tag)
                index += len(dollar_tag)
                continue
        if char == ";":
            statement = "".join(buffer).strip()
            if _executable(statement):
                statements.append(statement)
            buffer = []
            index += 1
            continue
        buffer.append(char)
        index += 1
    tail = "".join(buffer).strip()
    if _executable(tail):
        statements.append(tail)
    return statements


def _executable(statement: str) -> bool:
    without_block = re.sub(r"/\*.*?\*/", "", statement, flags=re.DOTALL)
    without_line = re.sub(r"--.*?$", "", without_block, flags=re.MULTILINE)
    return bool(without_line.strip())


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
                for statement in split_sql(rendered):
                    conn.execute(statement)
                applied.append(sql_file.name)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return applied


def _table_exists(url: str, schema: str, table: str) -> bool:
    with psycopg.connect(connectable_url(url), connect_timeout=8) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = %s AND table_name = %s
                """,
                (schema, table),
            )
            return cur.fetchone() is not None


def _apply_files(
    url: str,
    names: tuple[str, ...],
    *,
    users_schema: str,
    database: str,
    app_schema: str,
) -> list[str]:
    users = validate_schema_name(users_schema)
    app = validate_schema_name(app_schema)
    applied: list[str] = []
    with psycopg.connect(connectable_url(url), connect_timeout=8) as conn:
        try:
            conn.execute(f'CREATE SCHEMA IF NOT EXISTS "{users}"')
            conn.execute(f'SET search_path TO "{app}", "{users}", public')
            for name in names:
                sql_file = SQL_DIR / name
                rendered = render_sql(
                    sql_file.read_text(encoding="utf-8"),
                    app_schema=app,
                    users_schema=users,
                    database=database,
                )
                for statement in split_sql(rendered):
                    conn.execute(statement)
                applied.append(sql_file.name)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return applied


def apply_banking_ddl(
    url: str,
    *,
    users_schema: str,
    database: str = "neondb",
    app_schema: str = "public",
) -> list[str]:
    """Create the login tables if needed, the public banking model, then the statement flow.

    004 is destructive, so it runs only when ``public.bank_accounts_d`` is absent.
    006 is safe to repeat and does not delete uploaded CSV rows.
    """
    applied: list[str] = []
    if not _table_exists(url, validate_schema_name(users_schema), "users"):
        applied.extend(
            apply_users_ddl(url, users_schema=users_schema, database=database),
        )
    if not _table_exists(url, "public", "bank_accounts_d"):
        applied.extend(
            _apply_files(
                url,
                ("004_public_banking.sql",),
                users_schema=users_schema,
                database=database,
                app_schema=app_schema,
            ),
        )
    applied.extend(
        _apply_files(
            url,
            ("001_extensions.sql", "006_statement_flow.sql"),
            users_schema=users_schema,
            database=database,
            app_schema=app_schema,
        ),
    )
    return applied
