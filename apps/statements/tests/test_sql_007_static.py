"""Static analysis and idempotency tests for sql/007_multibank_profiles.sql.

Pure Python tests; does not connect to any database.
"""

import re
from pathlib import Path

SQL_FILE = Path(__file__).resolve().parents[3] / "sql" / "007_multibank_profiles.sql"


def _read_sql() -> str:
    assert SQL_FILE.exists(), f"File {SQL_FILE} does not exist"
    return SQL_FILE.read_text(encoding="utf-8")


def test_sql_007_no_destructive_commands():
    content = _read_sql()
    # Strip comments
    without_line_comments = re.sub(r"--.*?$", "", content, flags=re.MULTILINE)
    clean_sql = re.sub(r"/\*.*?\*/", "", without_line_comments, flags=re.DOTALL)

    # Must contain no DROP TABLE
    assert not re.search(r"\bDROP\s+TABLE\b", clean_sql, re.IGNORECASE)
    # Must contain no TRUNCATE
    assert not re.search(r"\bTRUNCATE\b", clean_sql, re.IGNORECASE)
    # Must contain no DELETE FROM user tables
    assert not re.search(r"\bDELETE\s+FROM\b", clean_sql, re.IGNORECASE)


def test_sql_007_seeds_banks():
    content = _read_sql()
    assert "HSBC" in content
    assert "BBVA" in content
    assert "banks_d" in content


def test_sql_007_creates_registry_table():
    content = _read_sql()
    assert re.search(r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+public\.file_profiles_d", content, re.IGNORECASE)
    assert "profile_code" in content
    assert "header_signature" in content
    assert "amount_rule" in content


def test_sql_007_seeds_required_profiles():
    content = _read_sql()
    for profile in (
        "banorte_debit_v1",
        "banorte_credit_monthly_v1",
        "banorte_credit_plan_v1",
        "hsbc_debit_v1",
    ):
        assert profile in content


def test_sql_007_drops_saldos_not_null():
    content = _read_sql()
    assert re.search(
        r"ALTER\s+TABLE\s+public\.master_debit_closed_f\s+ALTER\s+COLUMN\s+saldos\s+DROP\s+NOT\s+NULL",
        content,
        re.IGNORECASE,
    )
    assert re.search(
        r"ALTER\s+TABLE\s+public\.open_debit_f\s+ALTER\s+COLUMN\s+saldos\s+DROP\s+NOT\s+NULL",
        content,
        re.IGNORECASE,
    )


def test_sql_007_adds_required_columns():
    content = _read_sql()
    assert "source_profile TEXT" in content
    assert "encoding TEXT" in content
    assert "delimiter TEXT" in content
    assert "pagos_hechos INTEGER" in content
    assert "pagos_totales INTEGER" in content


def test_sql_007_creates_or_replaces_functions():
    content = _read_sql()
    assert re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.enforce_bank_account", content, re.IGNORECASE)
    assert re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.statement_home", content, re.IGNORECASE)
    assert re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.detect_profile", content, re.IGNORECASE)
    assert re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.ingest_statement_csv", content, re.IGNORECASE)


def test_sql_007_grants_strm_app():
    content = _read_sql()
    assert "GRANT EXECUTE ON FUNCTION public.ingest_statement_csv" in content
    assert "GRANT EXECUTE ON FUNCTION public.statement_home" in content
    assert "GRANT SELECT ON TABLE public.file_profiles_d TO strm_app" in content
