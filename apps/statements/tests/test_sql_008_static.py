"""Static checks for sql/008_bbva_header_mapping.sql."""

import re
from pathlib import Path

SQL_FILE = Path(__file__).resolve().parents[3] / "sql" / "008_bbva_header_mapping.sql"


def _read() -> str:
    assert SQL_FILE.exists()
    return SQL_FILE.read_text(encoding="utf-8")


def test_sql_008_seeds_bbva_profiles():
    content = _read()
    assert "bbva_debit_v1" in content
    assert "bbva_credit_v1" in content
    assert "split_credit_abs_income" in content


def test_sql_008_replace_open_by_account():
    content = _read()
    assert "replace_open_account_movements" in content
    assert re.search(r"DELETE\s+FROM\s+public\.open_debit_f", content, re.I)
    assert "account_id = p_account_id" in content


def test_sql_008_no_drop_table():
    content = _read()
    clean = re.sub(r"--.*?$", "", content, flags=re.M)
    assert not re.search(r"\bDROP\s+TABLE\b", clean, re.I)
