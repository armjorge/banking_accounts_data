"""Static checks for sql/009_clear_and_open_by_account.sql (no live DB)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "009_clear_and_open_by_account.sql").read_text(encoding="utf-8")


def test_009_clears_statement_tables():
    for table in (
        "open_debit_f",
        "open_credit_f",
        "master_debit_closed_f",
        "master_credit_closed_f",
        "credit_plan_closed_f",
        "statement_uploads_f",
        "movement_dimensions_d",
    ):
        assert f"public.{table}," in SQL or f"public.{table};" in SQL


def test_009_keeps_accounts_and_banks():
    assert "TRUNCATE TABLE public.bank_accounts_d" not in SQL
    assert "TRUNCATE TABLE public.banks_d" not in SQL
    assert "DROP TABLE IF EXISTS public." not in SQL
    assert "DROP TABLE public." not in SQL


def test_009_adds_period_ym():
    assert "period_ym" in SQL
    assert "YYYY-MM" in SQL


def test_009_reload_open_deletes_only_touched_accounts():
    assert "account_id = ANY (v_touched)" in SQL
    assert "accounts_replaced" in SQL
    # Per-account delete appears before re-insert; no bare tenant+user wipe without account filter.
    assert SQL.count("account_id = ANY (v_touched)") >= 2


def test_009_upsert_user_file_profile():
    assert "upsert_user_file_profile" in SQL
    assert "split_credit_abs_income" in SQL
    assert "GRANT EXECUTE ON FUNCTION public.upsert_user_file_profile" in SQL
