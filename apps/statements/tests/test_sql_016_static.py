"""Static checks on sql/016 (no database)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "016_lists_completeness_transfers.sql").read_text(
    encoding="utf-8"
)


def test_016_is_forward_only_and_keeps_data():
    assert "DROP TABLE public" not in SQL
    assert "TRUNCATE" not in SQL
    # The only deletes: auto links nobody reviewed whose movements are gone.
    deletes = re.findall(r"DELETE FROM public\.(\w+)", SQL)
    assert deletes == ["inter_accounts_d"]
    assert "AND link.source = 'auto'" in SQL and "AND link.reviewed_at IS NULL" in SQL
    for table in (
        "list_f",
        "list_d",
        "attribute_settings_d",
        "dimension_settings_d",
        "inter_accounts_d",
    ):
        assert f"CREATE TABLE IF NOT EXISTS public.{table}" in SQL


def test_016_rls_and_read_only_grants():
    for table in (
        "list_f",
        "list_d",
        "attribute_settings_d",
        "dimension_settings_d",
        "inter_accounts_d",
    ):
        assert f"ALTER TABLE public.{table} ENABLE ROW LEVEL SECURITY" in SQL
    grants = re.findall(r"GRANT (\w+) ON public\.([\w, .\n]+?) TO strm_app", SQL)
    assert {kind for kind, _ in grants} == {"SELECT"}
    for internal in (
        "transfer_detect",
        "transfer_pool",
        "dimension_store",
        "list_item_ensure",
    ):
        assert f"GRANT EXECUTE ON FUNCTION public.{internal}(" not in SQL


def test_016_keeps_015_callers_working():
    # Five-argument graphql_rows calls (deployed Lambda before the redeploy) still resolve.
    assert "p_exclude_transfers BOOLEAN DEFAULT FALSE" in SQL
    assert "save_dimension(\n    p_row_hash TEXT,\n    p_attribute_1 TEXT," in SQL
    assert "ADD COLUMN IF NOT EXISTS attribute_1_item_id BIGINT" in SQL


def test_016_upload_trigger_never_blocks_an_upload():
    body = SQL.split("FUNCTION public.detect_transfers_after_insert()")[1].split(
        "$fn$;"
    )[0]
    assert "EXCEPTION WHEN OTHERS THEN" in body and "RAISE WARNING" in body
