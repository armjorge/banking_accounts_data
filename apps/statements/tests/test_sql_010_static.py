"""Static checks for sql/010_bbva_xlsx_csv_ingest.sql."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "010_bbva_xlsx_csv_ingest.sql").read_text(encoding="utf-8")


def test_010_helpers_and_bbva_rules():
    assert "header_field_index" in SQL
    assert "is_statement_skip_row" in SQL
    assert "split_credit_abs_income" in SQL
    assert "descripcion" in SQL
    assert "digital" in SQL.lower()
    assert "titular" in SQL.lower()
    assert "period_ym" in SQL


def test_010_replaces_ingest():
    assert "CREATE OR REPLACE FUNCTION public.ingest_statement_csv" in SQL
    assert "v_header_record_no" in SQL
    assert "fp.dataset = v_dataset" in SQL


def test_010_accepts_cargo_aliases():
    assert "cargos', 'cargo'" in SQL or "'cargos', 'cargo'" in SQL
    assert "abonos', 'abono'" in SQL or "'abonos', 'abono'" in SQL


def test_010_forces_csv_filename_with_bank_account():
    assert "v_from_sheet" in SQL
    assert "bank_account_period.csv" in SQL or "FORMAT('%s_%s_%s.csv'" in SQL
    assert "original_filename', v_filename" in SQL
    assert "period_ym', v_period_ym" in SQL
    assert "account_number', v_account_number" in SQL
    assert "bank_name', v_bank_name" in SQL
    assert "file_suffix', 'csv'" in SQL
