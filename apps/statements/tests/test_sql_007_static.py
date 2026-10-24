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
    assert "setval" in content.lower()
    assert "pg_get_serial_sequence('public.banks_d', 'bank_id')" in content


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


def test_sql_007_no_undefined_columns_referenced():
    content = _read_sql()
    without_line_comments = re.sub(r"--.*?$", "", content, flags=re.MULTILINE)
    clean_sql = re.sub(r"/\*.*?\*/", "", without_line_comments, flags=re.DOTALL)

    defined_columns = {
        "cutoff_date_f": {
            "cutoff_id",
            "account_id",
            "user_id",
            "cutoff_month",
            "cutoff_year",
            "is_required",
            "cutoff_date",
            "tenant_id",
            "period_start",
            "period_end",
            "added_by_user",
        },
        "statement_uploads_f": {
            "upload_id",
            "tenant_id",
            "user_id",
            "account_id",
            "cutoff_id",
            "dataset",
            "original_filename",
            "content_sha256",
            "byte_size",
            "row_count",
            "storage_mode",
            "curated_s3_key",
            "body_text",
            "pdf_bytes",
            "created_at",
            "encoding",
            "delimiter",
            "source_profile",
        },
        "bank_accounts_d": {
            "account_id",
            "tenant_id",
            "user_id",
            "bank_id",
            "a_type_id",
            "account_name",
            "account_number",
            "account_cutoff_day",
            "credit_days",
        },
        "master_debit_closed_f": {
            "row_id",
            "file_id",
            "tenant_id",
            "user_id",
            "account_id",
            "account_number",
            "bank_name",
            "file_name",
            "period_start",
            "period_end",
            "txn_date",
            "concept",
            "concept_sk",
            "cargos",
            "abonos",
            "saldos",
            "amount",
            "occurrence",
            "row_hash",
            "source_profile",
        },
        "master_credit_closed_f": {
            "row_id",
            "file_id",
            "tenant_id",
            "user_id",
            "account_id",
            "account_number",
            "bank_name",
            "file_name",
            "period_start",
            "period_end",
            "txn_date",
            "concept",
            "concept_sk",
            "abono",
            "cargo",
            "tarjeta",
            "amount",
            "occurrence",
            "row_hash",
            "source_profile",
        },
        "credit_plan_closed_f": {
            "row_id",
            "file_id",
            "tenant_id",
            "user_id",
            "account_id",
            "account_number",
            "bank_name",
            "file_name",
            "period_start",
            "period_end",
            "txn_date",
            "concept",
            "concept_sk",
            "tasa_anual",
            "importe_inicial",
            "importe_pendiente",
            "pagos_pendientes",
            "pagos_hechos",
            "pagos_totales",
            "mensualidad",
            "amount",
            "occurrence",
            "row_hash",
            "source_profile",
        },
        "open_debit_f": {
            "row_id",
            "tenant_id",
            "user_id",
            "account_id",
            "account_number",
            "bank_name",
            "file_name",
            "txn_date",
            "concept",
            "concept_sk",
            "cargos",
            "abonos",
            "saldos",
            "amount",
            "occurrence",
            "row_hash",
        },
        "open_credit_f": {
            "row_id",
            "tenant_id",
            "user_id",
            "account_id",
            "account_number",
            "bank_name",
            "file_name",
            "txn_date",
            "concept",
            "concept_sk",
            "abono",
            "cargo",
            "tarjeta",
            "amount",
            "occurrence",
            "row_hash",
        },
    }

    alias_map = {
        "cutoff": "cutoff_date_f",
        "statement_file": "statement_uploads_f",
        "installment_file": "statement_uploads_f",
        "pdf_file": "statement_uploads_f",
        "upload": "statement_uploads_f",
        "account": "bank_accounts_d",
    }

    errors = []

    # 1. Check all alias.column references in SQL
    for alias, table_name in alias_map.items():
        allowed_cols = defined_columns[table_name]
        for m in re.finditer(rf"\b{alias}\.([A-Za-z0-9_]+)", clean_sql, re.IGNORECASE):
            col = m.group(1).lower()
            if col not in allowed_cols:
                errors.append(f"Undefined column '{alias}.{col}' for table '{table_name}'")

    # 2. Check NEW.column in enforce_bank_account()
    enforce_match = re.search(
        r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.enforce_bank_account.*?\$(?:fn)?\$(.*?)\$(?:fn)?\$",
        clean_sql,
        re.DOTALL | re.IGNORECASE,
    )
    if enforce_match:
        enforce_body = enforce_match.group(1)
        for m in re.finditer(r"\bNEW\.([A-Za-z0-9_]+)", enforce_body, re.IGNORECASE):
            col = m.group(1).lower()
            if col not in defined_columns["bank_accounts_d"]:
                errors.append(f"Undefined column 'NEW.{col}' for table 'bank_accounts_d'")

    # 3. Check columns in INSERT INTO public.<table_name> (...)
    for m in re.finditer(r"INSERT\s+INTO\s+public\.([A-Za-z0-9_]+)\s*\((.*?)\)", clean_sql, re.DOTALL | re.IGNORECASE):
        table_name = m.group(1).lower()
        cols_text = m.group(2)
        if table_name in defined_columns:
            allowed_cols = defined_columns[table_name]
            for col in re.split(r",|\s+", cols_text):
                col = col.strip().lower()
                if not col:
                    continue
                if col not in allowed_cols:
                    errors.append(f"Undefined column '{col}' in INSERT INTO public.{table_name}")

    assert not errors, "Undefined column references detected:\n" + "\n".join(errors)
