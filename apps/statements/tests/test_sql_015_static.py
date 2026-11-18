"""Static checks on sql/015 (no database)."""

from pathlib import Path

SQL = (Path(__file__).resolve().parents[3] / "sql" / "015_dimensions_api.sql").read_text(encoding="utf-8")


def test_015_is_forward_only_and_keeps_data():
    assert "DROP TABLE" not in SQL
    assert "TRUNCATE" not in SQL
    assert "DELETE FROM" not in SQL
    assert "CREATE TABLE IF NOT EXISTS public.debit_d" in SQL
    assert "CREATE TABLE IF NOT EXISTS public.credit_d" in SQL
    assert "ON CONFLICT (row_hash) DO NOTHING" in SQL


def test_015_quota_columns_are_data_not_code():
    for column in ("api_calls_limit", "api_window", "api_max_rows"):
        assert f"ADD COLUMN IF NOT EXISTS {column}" in SQL
    # Only empty values get defaults, so edits in plans_d survive a re-run.
    assert "WHERE api_calls_limit IS NULL OR api_window IS NULL OR api_max_rows IS NULL" in SQL
    assert "PG_ADVISORY_XACT_LOCK" in SQL


def test_015_grants_keep_the_clock_and_hashes_private():
    assert "GRANT EXECUTE ON FUNCTION public.api_consume_call_at" not in SQL
    assert "GRANT EXECUTE ON FUNCTION public.api_consume_call(" not in SQL
    assert "GRANT SELECT ON public.api_tokens_d" not in SQL
    assert "token_sha256" not in SQL.split("GRANT SELECT (token_id")[1].split(";")[0]
    for table in ("debit_d", "credit_d", "api_tokens_d", "api_usage_f"):
        assert f"ALTER TABLE public.{table} ENABLE ROW LEVEL SECURITY" in SQL
