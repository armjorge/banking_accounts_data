"""Static checks for sql/014_normalized_row_hash.sql and its callers."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "014_normalized_row_hash.sql").read_text(encoding="utf-8")
DOC = (ROOT / "docs" / "row_hash.md").read_text(encoding="utf-8")
MASTERS = (
    "master_debit_closed_f",
    "master_debit_open_f",
    "master_credit_closed_f",
    "master_credit_open_f",
    "master_credit_future_f",
)


def test_014_hash_function_and_docs():
    assert "CREATE OR REPLACE FUNCTION public.movement_row_hash_v2(" in SQL
    assert "COMMENT ON FUNCTION public.movement_row_hash_v2(" in SQL
    assert "user_id | account_id | bank_id | txn_date | concept_sk | abonos | cargos | occurrence" in DOC
    for heading in ("## Signs", "Worked example", "Occurrence (decision to confirm)", "## Not in the key"):
        assert heading in DOC or heading.replace("## ", "### ") in DOC


def test_014_columns_constraints_and_comments():
    assert "RENAME COLUMN abono TO abonos" in SQL
    assert "RENAME COLUMN cargo TO cargos" in SQL
    for table in MASTERS:
        assert f"ALTER TABLE public.{table}\nADD COLUMN IF NOT EXISTS bank_id INTEGER;" in SQL
        assert f"COMMENT ON COLUMN public.{table}.row_hash IS" in SQL
        assert f"COMMENT ON COLUMN public.{table}.cargos IS" in SQL
        assert f"FROM public.{table} AS movement" in SQL
    assert "'cargos <= 0 AND abonos >= 0'" in SQL
    assert "'cargos >= 0 AND abonos >= 0'" in SQL
    assert "NOT VALID" in SQL


def test_014_rewrites_writers_and_never_truncates():
    assert "public.movement_row_hash(" not in SQL.split("COMMENT ON FUNCTION public.movement_row_hash(")[0]
    assert SQL.count("public.movement_row_hash_v2(") >= 6
    assert "CREATE OR REPLACE FUNCTION public.ingest_statement_csv(" in SQL
    assert "CREATE OR REPLACE FUNCTION public.update_bank_account_cutoff(" in SQL
    assert "abono, cargo, tarjeta" not in SQL
    assert "TRUNCATE public." not in SQL
    # The only drop: an empty master_debit_future_f recreated by re-running 011 after 014.
    assert [line.strip() for line in SQL.splitlines() if "DROP TABLE public." in line] == [
        "DROP TABLE public.master_debit_future_f;"
    ]
    assert "RENAME TO master_credit_future_f" in SQL
    assert "ENABLE TRIGGER master_debit_closed_f_no_update" in SQL
    assert "ENABLE TRIGGER master_credit_closed_f_no_update" in SQL
    assert "WITH (security_invoker = TRUE)" in SQL
    assert "GRANT SELECT ON public.movement_keys_v TO strm_app" in SQL
