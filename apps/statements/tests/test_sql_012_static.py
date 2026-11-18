"""Static checks for sql/012_edit_credit_cutoff.sql (live checks are in test_statement_flow.py)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SQL = (ROOT / "sql" / "012_edit_credit_cutoff.sql").read_text(encoding="utf-8")
LOCAL_API = (ROOT / "apps" / "statements" / "local_api.py").read_text(encoding="utf-8")
LAMBDA = (ROOT / "infra" / "lambda" / "statements.ts").read_text(encoding="utf-8")
STACK = (ROOT / "infra" / "lib" / "environment-stack.ts").read_text(encoding="utf-8")
WEB = (ROOT / "web" / "statements.js").read_text(encoding="utf-8")


def test_012_defines_update_with_session_security():
    body = SQL.split("CREATE OR REPLACE FUNCTION public.update_bank_account_cutoff(", 1)[1]
    body = body.split("$fn$;", 1)[0]
    assert "SECURITY DEFINER" in body
    assert "SET search_path = public" in body
    assert "public.require_session()" in body
    assert "account.tenant_id = v_tenant" in body
    assert "account.user_id = v_user" in body
    assert "FOR UPDATE OF account" in body
    assert (
        "GRANT EXECUTE ON FUNCTION public.update_bank_account_cutoff(INTEGER, INTEGER, INTEGER, DATE) TO strm_app"
        in SQL
    )
    # The planner is internal: no grant to the app role.
    assert not re.search(r"GRANT EXECUTE ON FUNCTION public\.planned_statement_periods", SQL)


def test_012_never_rewrites_loaded_periods():
    refresh = SQL.split("CREATE OR REPLACE FUNCTION public.refresh_statement_periods(", 1)[1]
    refresh = refresh.split("$fn$;", 1)[0]
    assert "ON CONFLICT (account_id, cutoff_year, cutoff_month) DO UPDATE" in refresh
    assert "WHERE NOT EXISTS (" in refresh
    assert "upload.cutoff_id = cutoff.cutoff_id" in refresh
    assert not re.search(r"\bTRUNCATE\b|DROP TABLE", SQL, re.IGNORECASE)


def test_012_routes_and_ui():
    assert "/accounts/(\\d+)/cutoff" in LOCAL_API
    assert "update_bank_account_cutoff" in LOCAL_API
    assert "update_bank_account_cutoff" in LAMBDA
    assert 'path: "/accounts/{accountId}/cutoff"' in STACK
    assert "/accounts/${accountId}/cutoff" in WEB
    # POST only: no PATCH needed in CORS.
    assert "PATCH" not in LOCAL_API
