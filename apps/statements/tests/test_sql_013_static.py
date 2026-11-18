"""Static checks for sql/013_chosen_names_vault_keys.sql and its callers."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "013_chosen_names_vault_keys.sql").read_text(encoding="utf-8")
LAMBDA = (ROOT / "infra" / "lambda" / "statements.ts").read_text(encoding="utf-8")
LOCAL_API = (ROOT / "apps" / "statements" / "local_api.py").read_text(encoding="utf-8")
WEB = (ROOT / "web" / "statements.js").read_text(encoding="utf-8")
SCRIPT = (ROOT / "scripts" / "curated_key_migration.py").read_text(encoding="utf-8")


def test_013_backfill_keeps_existing_names():
    assert "ADD COLUMN IF NOT EXISTS chosen_filename TEXT" in SQL
    assert re.search(
        r"SET\s+chosen_filename = original_filename,\s+chosen_filename_source = 'legacy'\s+"
        r"WHERE chosen_filename IS NULL",
        SQL,
    )
    assert "original_filename =" not in SQL.split("WHERE chosen_filename IS NULL", 1)[0].split("UPDATE", 1)[1]
    assert not re.search(r"\bTRUNCATE\b|DROP TABLE|DROP COLUMN", SQL, re.IGNORECASE)


def test_013_migration_functions_are_owner_only():
    assert "GRANT EXECUTE ON FUNCTION public.curated_key_migration_plan" not in SQL
    assert "GRANT EXECUTE ON FUNCTION public.apply_curated_key_migration" not in SQL
    assert "REVOKE ALL ON FUNCTION public.curated_key_migration_plan(TEXT) FROM PUBLIC" in SQL


def test_lambda_and_clients_use_chosen_name_and_standard_key():
    assert "public.ingest_statement_upload(" in LAMBDA
    assert "public.ingest_period_pdf_upload(" in LAMBDA
    assert "payload.vault_key" in LAMBDA
    assert "${payload.upload_id}.${suffix}" not in LAMBDA
    assert 'IfNoneMatch: "*"' in LAMBDA
    assert 'ObjectLockMode: "GOVERNANCE"' in LAMBDA
    assert "public.vault_delete_marker(" in LAMBDA
    assert "Metadata: metadata" in LAMBDA
    assert "vaultManifest" in LAMBDA
    assert "public.ingest_statement_upload(" in LOCAL_API
    assert "chosen_filename: file.name" in WEB


def test_migration_script_never_deletes():
    assert "delete_object" not in SCRIPT
    assert "BypassGovernanceRetention" not in SCRIPT
    assert "--confirm-bucket" in SCRIPT


def test_013_vault_names_are_readable_and_registered():
    assert "CREATE TABLE IF NOT EXISTS public.curated_vault_keys_d" in SQL
    # The registry has no foreign key to uploads: names outlive deleted uploads.
    table = SQL.split("CREATE TABLE IF NOT EXISTS public.curated_vault_keys_d", 1)[1].split(");", 1)[0]
    assert "REFERENCES" not in table
    assert "'_msi'" in SQL
    assert "'_v' || v_version" in SQL
    assert "upload8" not in SQL.split("-- Safe to run more than once", 1)[1]
    assert "GRANT SELECT ON public.curated_vault_keys_d" not in SQL
