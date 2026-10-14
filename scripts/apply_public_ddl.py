"""Apply neondb.public banking DDL.

001-004 still use {{NEON_*}} placeholders and stay on the Streamlit path.
This script applies the hardcoded public model in sql/005_public_banking.sql.
It expects public.users_d to already exist.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "apps" / "config_console"))

from catalog import connectable_url  # noqa: E402

SQL_DIR = ROOT / "sql"
DDL_FILES = ("005_public_banking.sql",)
EXPECTED_DATABASE = "neondb"


def statements(sql_text: str) -> list[str]:
    return [part.strip() for part in sql_text.split(";") if part.strip()]


def require_database(conn: psycopg.Connection) -> None:
    row = conn.execute("SELECT current_database()").fetchone()
    database = row[0] if row else ""
    if database != EXPECTED_DATABASE:
        raise SystemExit(
            f"Refusing to apply DDL: connected to {database}, expected {EXPECTED_DATABASE}"
        )


def require_users_d(conn: psycopg.Connection) -> None:
    row = conn.execute(
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'users_d'
          AND column_name = 'user_id'
        """
    ).fetchone()
    if row is None:
        raise SystemExit("neondb.public.users_d.user_id must already exist")
    if row[0] != "integer":
        raise SystemExit(
            f"neondb.public.users_d.user_id must be integer, found {row[0]}"
        )


def apply(url: str) -> list[str]:
    applied: list[str] = []
    with psycopg.connect(connectable_url(url), connect_timeout=15) as conn:
        require_database(conn)
        require_users_d(conn)
        for name in DDL_FILES:
            sql_file = SQL_DIR / name
            for statement in statements(sql_file.read_text(encoding="utf-8")):
                conn.execute(statement)
            applied.append(sql_file.name)
        conn.commit()
    return applied


def main() -> None:
    url = os.environ.get("NEON_DATABASE_URL", "").strip()
    if not url:
        raise SystemExit("NEON_DATABASE_URL is not set")
    applied = apply(url)
    print("applied " + ", ".join(applied))


if __name__ == "__main__":
    main()
