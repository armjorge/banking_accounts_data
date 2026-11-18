"""Static checks for sql/011_open_future_ledgers.sql (live checks are in test_statement_flow.py)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "011_open_future_ledgers.sql").read_text(encoding="utf-8")


def test_011_creates_open_and_future_masters():
    for table in ("master_debit_open_f", "master_credit_open_f", "master_debit_future_f"):
        assert f"CREATE TABLE IF NOT EXISTS public.{table}" in SQL
        assert f"ALTER TABLE public.{table} ENABLE ROW LEVEL SECURITY" in SQL
        assert f"CREATE POLICY {table}_tenant ON public.{table}" in SQL
        assert f"CREATE UNIQUE INDEX IF NOT EXISTS {table}_hash_idx" in SQL


def test_011_never_truncates_or_writes_legacy_tables():
    assert not re.search(r"\bTRUNCATE\b", SQL, re.I)
    assert not re.search(r"INSERT\s+INTO\s+public\.credit_plan_closed_f", SQL, re.I)
    assert not re.search(r"INSERT\s+INTO\s+public\.open_(debit|credit)_f", SQL, re.I)
    assert "DROP TABLE" not in SQL


def test_011_per_account_replace():
    assert "WHERE account_id = $1 AND tenant_id = $2 AND user_id = $3" in SQL
    assert "no payments due after" in SQL


def test_011_replaces_ingest_home_and_periods():
    for name in (
        "ingest_statement_csv",
        "statement_home",
        "refresh_statement_periods",
        "delete_statement_upload",
        "current_period",
        "future_cutoff_periods",
    ):
        assert f"CREATE OR REPLACE FUNCTION public.{name}(" in SQL
    assert "DROP FUNCTION IF EXISTS public.reload_open_movements(JSONB)" in SQL


def test_011_bbva_paid_count_installments():
    assert "'bbva_credit_plan_v1'" in SQL
    for name in ("spanish_short_date", "undouble_amount", "installment_paid_counts", "reshape_one_column_installments"):
        assert f"CREATE OR REPLACE FUNCTION public.{name}(" in SQL
        assert f"GRANT EXECUTE ON FUNCTION public.{name}(TEXT) TO strm_app" in SQL
    # No amount_rule CHECK change: 007/008 stay re-runnable after 011.
    assert "file_profiles_d_amount_rule_check" not in SQL
    assert "v_col_map ? 'pagos_hechos'" in SQL
    assert "src.schedule_kind = 'purchase_day'" in SQL
