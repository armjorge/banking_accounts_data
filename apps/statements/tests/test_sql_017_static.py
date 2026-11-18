"""Static checks on sql/017 and the files that expose it (no database)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "017_investments_assets.sql").read_text(encoding="utf-8")
LAMBDA = (ROOT / "infra" / "lambda" / "statements.ts").read_text(encoding="utf-8")
STACK = (ROOT / "infra" / "lib" / "environment-stack.ts").read_text(encoding="utf-8")
LOCAL_API = (ROOT / "apps" / "statements" / "local_api.py").read_text(encoding="utf-8")
CODE_GS = (ROOT / "integrations" / "google_sheets" / "Code.gs").read_text(encoding="utf-8")
WEB = ROOT / "web"
TABLES = (
    "aaccandass_templates_d",
    "aaccandass_uploads_f",
    "master_closed_aaccandass_f",
    "master_closed_aaccandass_d",
    "aaccandass_checks_f",
)


def test_017_is_forward_only_and_keeps_data():
    assert "DROP TABLE public" not in SQL and "TRUNCATE" not in SQL
    for table in TABLES:
        assert f"CREATE TABLE IF NOT EXISTS public.{table}" in SQL
    # Deletes only on the new tables, from user actions (row, file, template).
    deletes = set(re.findall(r"DELETE FROM public\.(\w+)", SQL))
    assert deletes <= set(TABLES)
    # Uploaded rows are never updated.
    assert "BEFORE UPDATE ON public.master_closed_aaccandass_f" in SQL
    assert not re.search(r"UPDATE public\.master_closed_aaccandass_f\b", SQL)


def test_017_rls_and_read_only_grants():
    for table in TABLES:
        assert f"ALTER TABLE public.{table} ENABLE ROW LEVEL SECURITY" in SQL
        assert f"'{table}'" in SQL.split("DO $policies$")[1].split("$policies$;")[0]
    grants = re.findall(r"GRANT (\w+)(?: \([^)]*\))? ON public\.", SQL)
    assert set(grants) == {"SELECT"}
    # The uploaded file body stays behind the functions.
    upload_grant = SQL.split("GRANT SELECT (")[1].split(") ON public.aaccandass_uploads_f")[0]
    assert "body_text" not in upload_grant
    for internal in (
        "aaccandass_account",
        "aaccandass_store_row",
        "aaccandass_balance_at",
        "aaccandass_reserve_vault_key",
        "aaccandass_vault_manifest",
        "dimension_store",
    ):
        assert f"GRANT EXECUTE ON FUNCTION public.{internal}(" not in SQL
        assert f"REVOKE ALL ON FUNCTION public.{internal}(" in SQL


def test_017_session_checked_entry_points():
    for name in (
        "create_asset_account",
        "add_aaccandass_row",
        "delete_aaccandass_row",
        "reconcile_aaccandass",
        "aaccandass_preview",
        "ingest_aaccandass_upload",
        "attach_aaccandass_backup",
        "delete_aaccandass_upload",
        "delete_aaccandass_template",
        "aaccandass_balance",
        "aaccandass_balances",
        "aaccandass_home",
        "aaccandass_rows",
    ):
        body = SQL.split(f"FUNCTION public.{name}(")[1].split("$fn$;")[0]
        assert "require_session()" in body, name
        assert "SECURITY DEFINER" in body and "SET search_path = public" in body, name


def test_017_row_hash_and_shared_views():
    assert SQL.count("public.movement_row_hash_v2(") >= 3
    assert "'master_closed_aaccandass_f'::TEXT AS source_table" in SQL
    assert "FROM public.master_closed_aaccandass_d AS dim" in SQL
    assert "('asset', 'closed')" in SQL
    assert "'master_closed_aaccandass_f'\n    ) THEN" in SQL
    assert "ARRAY['debit_d', 'credit_d', 'master_closed_aaccandass_d']" in SQL
    assert "kind.ledger_kind <> 'asset'" in SQL


def test_006_rerun_accepts_asset_types():
    sql006 = (ROOT / "sql" / "006_statement_flow.sql").read_text(encoding="utf-8")
    check = sql006.split("ADD CONSTRAINT account_types_d_ledger_kind_check CHECK (")[1].split(");")[0]
    assert "ledger_kind = 'asset'" in check


def test_017_no_personal_identifiers():
    fixture = (ROOT / "apps" / "statements" / "tests" / "fixtures" / "infonavit_aportaciones_anon.csv").read_text(
        encoding="utf-8"
    )
    for text in (SQL, fixture, CODE_GS):
        # No RFC (4 letters + 6 digits + 3) and no 18-digit CLABE.
        assert not re.search(r"\b[A-ZÑ&]{4}\d{6}[A-Z0-9]{3}\b", text)
        assert not re.search(r"\b\d{18}\b", text)


def test_routes_match_in_lambda_stack_and_local_api():
    routes = {
        ("GET", "/assets"),
        ("GET", "/assets/balances"),
        ("POST", "/assets/accounts"),
        ("GET", "/assets/rows"),
        ("POST", "/assets/rows"),
        ("DELETE", "/assets/rows/{rowHash}"),
        ("POST", "/assets/reconcile"),
        ("POST", "/assets/preview"),
        ("POST", "/assets/uploads"),
        ("DELETE", "/assets/uploads/{uploadId}"),
        ("DELETE", "/assets/templates/{templateId}"),
    }
    for method, path in routes:
        line = next(line for line in STACK.splitlines() if f'["{path}", [' in line)
        assert f"HttpMethod.{method}" in line, (method, path)
    for fn in (
        "aaccandass_home",
        "aaccandass_balances",
        "create_asset_account",
        "aaccandass_rows",
        "add_aaccandass_row",
        "delete_aaccandass_row",
        "reconcile_aaccandass",
        "aaccandass_preview",
        "ingest_aaccandass_upload",
        "delete_aaccandass_upload",
        "delete_aaccandass_template",
    ):
        assert f"public.{fn}(" in LAMBDA and f"public.{fn}(" in LOCAL_API, fn
    assert "public.attach_aaccandass_backup(" in LAMBDA
    assert "putVaultObject(" in LAMBDA.split("async function dispatch017(")[1]


def test_sheets_has_sixth_tab_and_web_page():
    assert "['master_closed_aaccandass_f', 'ASSET', 'CLOSED', 12," in CODE_GS
    assert "'source_profile', 'balance'," in CODE_GS
    dims = (WEB / "dimensions.js").read_text(encoding="utf-8")
    assert '{ id: "assets", title: "Investments & Assets" }' in dims
    assert '{ kind: "asset", title: "Investments & assets", layers: ["closed"] }' in dims
    for page in ("index.html", "preview.html"):
        html = (WEB / page).read_text(encoding="utf-8")
        assert '<script src="./assets.js?v=' in html
        assert html.index("dimensions.js") < html.index("assets.js")
