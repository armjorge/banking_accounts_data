"""sql/015: attribute tables, dimensions page functions, API tokens, quotas, GraphQL API."""

from __future__ import annotations

import json
import threading
import uuid
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest
from postgres_ops import _apply_files, apply_banking_ddl
from statements import graphql_api
from test_statement_flow import (
    CREDIT_CSV,
    DEBIT_CSV,
    LATER_MIGRATIONS,
    MSI_AS_OF,
    OPEN_CREDIT_CSV,
    OPEN_DEBIT_CSV,
    _admin,
    _apply_all_ddl,
    _create,
    _current,
    _ensure_login_role,
    _expect_error,
    _ingest,
    _json,
    _msi_text,
    _period,
    _session,
    _update_cutoff,
    _user,
)

MEXICO = ZoneInfo("America/Mexico_City")
ALL_TABS = """
query RefreshAll {
  debitClosed: movements(kind: DEBIT, layer: CLOSED, months: 120) { txn_date concept_sk abonos cargos attribute_1 }
  debitOpen: movements(kind: DEBIT, layer: OPEN) { txn_date concept_sk abonos cargos amount }
  creditClosed: movements(kind: CREDIT, layer: CLOSED, months: 120) { txn_date concept_sk abonos cargos amount }
  creditOpen: movements(kind: CREDIT, layer: OPEN) { txn_date concept_sk abonos cargos }
  creditFuture: movements(kind: CREDIT, layer: FUTURE) { txn_date concept_sk cargos attribute_2 }
  usage { used limit window resets_at }
}
"""


@pytest.fixture(scope="module")
def database_url():
    _ensure_login_role()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin = _admin()
    admin.execute(f'CREATE DATABASE "{name}"')
    admin.close()
    url = f"postgresql:///{name}?sslmode=disable"
    _apply_all_ddl(url)
    yield url
    admin = _admin()
    admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
    admin.close()


@pytest.fixture
def conn(database_url):
    connection = psycopg.connect(database_url)
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()


def _seed(conn, email, plan="premium"):
    """One user with a debit and a credit account: closed, open and future rows."""
    user_id, tenant_id = _user(conn, email)
    _session(conn, user_id, tenant_id)
    conn.execute("UPDATE public.tenants_d SET plan_code = %s WHERE tenant_id = %s", (plan, tenant_id))
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
    _ingest(conn, debit_id, _current(conn, debit_id, MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", OPEN_DEBIT_CSV, MSI_AS_OF)
    _ingest(conn, credit_id, _period(conn, credit_id, "2026-11", MSI_AS_OF)["cutoff_id"],
            "statement", "3978.csv", CREDIT_CSV, MSI_AS_OF)
    slot = _current(conn, credit_id, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, credit_id, slot, "statement", "3978.csv", OPEN_CREDIT_CSV, MSI_AS_OF)
    _ingest(conn, credit_id, slot, "installment", "msi.csv", _msi_text(), MSI_AS_OF)
    return user_id, tenant_id, debit_id, credit_id


def _token(conn, name="Sheets"):
    created = _json(conn.execute("SELECT public.create_api_token(%s)", (name,)).fetchone()[0])
    return created


def _gql(database_url, token, query, variables=None, at=None):
    body = json.dumps({"query": query, "variables": variables or {}})
    with psycopg.connect(database_url) as conn:
        return graphql_api.handle(conn, f"Bearer {token}", body, at)


def _calls(conn, user_id):
    return conn.execute(
        "SELECT status, COUNT(*) FROM public.api_usage_f WHERE user_id = %s GROUP BY status ORDER BY status",
        (user_id,),
    ).fetchall()


# --- attributes -------------------------------------------------------------------------


def test_attribute_rows_cover_every_movement_and_follow_open_to_closed(conn):
    user_id, _tenant_id, debit_id, _ = _seed(conn, "attrs@example.com")
    for table, attrs in (
        ("master_debit_closed_f", "debit_d"), ("master_debit_open_f", "debit_d"),
        ("master_credit_closed_f", "credit_d"), ("master_credit_open_f", "credit_d"),
        ("master_credit_future_f", "credit_d"),
    ):
        missing = conn.execute(
            f"SELECT COUNT(*) FROM public.{table} AS m LEFT JOIN public.{attrs} AS a USING (row_hash) "
            "WHERE m.user_id = %s AND a.row_hash IS NULL",
            (user_id,),
        ).fetchone()[0]
        assert missing == 0, table
    open_row = conn.execute(
        "SELECT row_hash FROM public.master_debit_open_f WHERE account_id = %s ORDER BY row_id LIMIT 1",
        (debit_id,),
    ).fetchone()[0]
    saved = _json(conn.execute(
        "SELECT public.save_dimension(%s, %s, %s, %s)", (open_row, " Rent ", "", None)
    ).fetchone()[0])
    assert (saved["kind"], saved["attribute_1"], saved["attribute_2"]) == ("debit", "Rent", None)
    # The period closes: same movement, same row_hash, now in the closed book.
    conn.execute(
        """
        INSERT INTO public.master_debit_closed_f (
            file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept,
            abonos, cargos, concept_sk, row_hash, occurrence
        )
        SELECT file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept,
            abonos, cargos, concept_sk, row_hash, occurrence
        FROM public.master_debit_open_f WHERE row_hash = %s
        """,
        (open_row,),
    )
    conn.execute("DELETE FROM public.master_debit_open_f WHERE row_hash = %s", (open_row,))
    rows = _json(conn.execute("SELECT public.dimension_rows('debit', 'closed')").fetchone()[0])["rows"]
    moved = next(row for row in rows if row["row_hash"] == open_row)
    assert moved["attribute_1"] == "Rent"


def test_summary_rows_filters_and_save_rules(conn):
    _user_id, _tenant_id, _debit_id, _credit_id = _seed(conn, "summary@example.com")
    summary = _json(conn.execute("SELECT public.dimension_summary()").fetchone()[0])
    assert summary["debit"]["layers"]["closed"] == {"total": 3, "filled": 0, "transfers": 0, "pct": 0}
    assert summary["credit"]["layers"]["future"]["total"] == 8
    assert set(summary["credit"]["layers"]) == {"open", "closed", "future"}
    assert set(summary["debit"]["layers"]) == {"open", "closed"}

    rows = _json(conn.execute("SELECT public.dimension_rows('debit', 'open')").fetchone()[0])
    assert rows["total"] == 3
    first = rows["rows"][0]
    assert {"account_number", "bank_name", "txn_date", "concept_sk", "abonos", "cargos",
            "attribute_1", "attribute_2", "attribute_3", "row_hash"} <= set(first)
    conn.execute("SELECT public.save_dimension(%s, 'Food', NULL, NULL)", (first["row_hash"],))
    summary = _json(conn.execute("SELECT public.dimension_summary()").fetchone()[0])
    assert summary["debit"]["layers"]["open"] == {"total": 3, "filled": 1, "transfers": 0, "pct": 33.3}
    assert summary["debit"]["filled"] == 1

    dated = _json(conn.execute(
        "SELECT public.dimension_rows('debit', 'open', '2026-11-05', '2026-11-05')"
    ).fetchone()[0])
    assert dated["total"] == 2
    named = _json(conn.execute(
        "SELECT public.dimension_rows('debit', 'open', NULL, NULL, 'nomina')"
    ).fetchone()[0])
    assert [row["concept"] for row in named["rows"]] == ["DEPOSITO NOMINA 0639"]
    by_attribute = _json(conn.execute(
        "SELECT public.dimension_rows('debit', 'open', NULL, NULL, 'food')"
    ).fetchone()[0])
    assert by_attribute["total"] == 1
    by_bank = _json(conn.execute(
        "SELECT public.dimension_rows('credit', 'future', NULL, NULL, 'banorte')"
    ).fetchone()[0])
    assert by_bank["total"] == 8
    _expect_error(conn, "SELECT public.dimension_rows('debit', 'future')", (), "unknown kind/layer", "22023")
    _expect_error(conn, "SELECT public.save_dimension(%s, %s, NULL, NULL)",
                  (first["row_hash"], "x" * 501), "500 characters", "22023")

    other, other_tenant = _user(conn, "summary-other@example.com")
    _session(conn, other, other_tenant)
    _expect_error(conn, "SELECT public.save_dimension(%s, 'mine', NULL, NULL)",
                  (first["row_hash"],), "movement not found", "P0002")
    assert _json(conn.execute("SELECT public.dimension_rows('debit', 'open')").fetchone()[0])["total"] == 0
    conn.execute("SET ROLE strm_app")
    assert conn.execute("SELECT COUNT(*) FROM public.debit_d").fetchone()[0] == 0
    conn.execute("RESET ROLE")


def test_redated_installments_keep_their_attributes(conn):
    user_id, tenant_id = _user(conn, "rekey@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    slot = _current(conn, credit_id, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, credit_id, slot, "installment", "msi.csv", _msi_text(), MSI_AS_OF)
    rows = conn.execute(
        "SELECT row_hash, concept_sk, occurrence FROM public.master_credit_future_f "
        "WHERE account_id = %s ORDER BY txn_date, concept_sk", (credit_id,)
    ).fetchall()
    conn.execute("SELECT public.save_dimension(%s, 'Phone', 'MSI', NULL)", (rows[0][0],))
    assert _update_cutoff(conn, credit_id, 20, 20)["future_rows_redated"] == 8
    new_hash = conn.execute(
        "SELECT row_hash FROM public.master_credit_future_f WHERE account_id = %s "
        "ORDER BY txn_date, concept_sk LIMIT 1", (credit_id,)
    ).fetchone()[0]
    assert new_hash != rows[0][0]
    assert conn.execute(
        "SELECT attribute_1, attribute_2 FROM public.credit_d WHERE row_hash = %s", (new_hash,)
    ).fetchone() == ("Phone", "MSI")


# --- tokens and quotas -----------------------------------------------------------------


def test_plan_quota_defaults_are_editable_columns(conn):
    plans = {
        code: (limit, window)
        for code, limit, window in conn.execute(
            "SELECT plan_code, api_calls_limit, api_window FROM public.plans_d"
        ).fetchall()
    }
    assert plans == {
        "free": (1, "week"),
        "entry": (1, "week"),
        "plus": (3, "day"),
        "premium": (3, "day"),
    }
    _expect_error(conn, "UPDATE public.plans_d SET api_window = 'month' WHERE plan_code = 'free'", (),
                  "plans_d_api_quota_check", "23514")


def test_plan_quota_edits_survive_reapplying_006_and_015():
    _ensure_login_role()
    admin = _admin()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin.execute(f'CREATE DATABASE "{name}"')
    url = f"postgresql:///{name}?sslmode=disable"
    kw = {"users_schema": "cognito_users", "database": "neondb", "app_schema": "public"}
    try:
        _apply_all_ddl(url)
        with psycopg.connect(url) as conn:
            conn.execute("UPDATE public.plans_d SET api_calls_limit = 2, api_window = 'day' WHERE plan_code = 'free'")
        apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
        _apply_files(url, LATER_MIGRATIONS[LATER_MIGRATIONS.index("011_open_future_ledgers.sql"):], **kw)
        with psycopg.connect(url) as conn:
            assert conn.execute(
                "SELECT api_calls_limit, api_window FROM public.plans_d WHERE plan_code = 'free'"
            ).fetchone() == (2, "day")
    finally:
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.close()


def test_tokens_are_hashed_listed_and_revoked(conn, database_url):
    user_id, tenant_id, *_ = _seed(conn, "tokens@example.com")
    created = _token(conn)
    conn.commit()
    assert created["token"].startswith("bst_") and len(created["token"]) == 52
    stored = conn.execute(
        "SELECT token_sha256, token_prefix FROM public.api_tokens_d WHERE token_id = %s",
        (created["token_id"],),
    ).fetchone()
    assert stored[0] != created["token"] and created["token"] not in json.dumps(stored)
    assert stored[1] == created["token"][:10]
    listed = _json(conn.execute("SELECT public.list_api_tokens()").fetchone()[0])
    assert [item["token_id"] for item in listed] == [created["token_id"]]
    assert "token" not in listed[0] and "token_sha256" not in listed[0]
    conn.execute("SET ROLE strm_app")
    _expect_error(conn, "SELECT token_sha256 FROM public.api_tokens_d", (), "permission denied")
    conn.execute("RESET ROLE")

    status, payload, _ = _gql(database_url, created["token"], "{ usage { used } }")
    assert status == 200 and payload["data"]["usage"]["used"] == 1
    _session(conn, user_id, tenant_id)
    conn.execute("SELECT public.revoke_api_token(%s)", (created["token_id"],))
    conn.commit()
    status, payload, _ = _gql(database_url, created["token"], "{ usage { used } }")
    assert (status, payload) == (401, {"error": "invalid or revoked API token"})
    assert _gql(database_url, "bst_" + "0" * 48, "{ usage { used } }")[0] == 401
    for _ in range(5):
        _token(conn)
    _expect_error(conn, "SELECT public.create_api_token('sixth')", (), "At most 5 active tokens")


def test_free_quota_hits_429_and_resets_next_week(conn, database_url):
    user_id, tenant_id, *_ = _seed(conn, "free-quota@example.com", plan="free")
    token = _token(conn)["token"]
    conn.commit()
    monday = datetime(2026, 11, 9, 9, 0, tzinfo=MEXICO)
    status, payload, _ = _gql(database_url, token, ALL_TABS, at=monday)
    assert status == 200, payload
    assert payload["extensions"]["usage"]["used"] == 1
    status, body, headers = _gql(database_url, token, ALL_TABS, at=monday + timedelta(days=3))
    assert status == 429
    assert body["code"] == "QUOTA_EXCEEDED"
    assert "1 call per week" in body["error"]
    assert body["limit"] == 1 and body["window"] == "week"
    reset = datetime.fromisoformat(body["resets_at"])
    assert reset == datetime(2026, 11, 16, 0, 0, tzinfo=MEXICO)
    assert body["resets_at"] in body["error"]
    assert int(headers["retry-after"]) == int((reset - (monday + timedelta(days=3))).total_seconds())
    # A bad request is refused before the quota is touched.
    assert _gql(database_url, token, "{ movements(kind: DEBIT) { txn_date } }", at=monday)[0] == 400
    # Next Monday (America/Mexico_City) the window is new.
    status, payload, _ = _gql(database_url, token, ALL_TABS, at=datetime(2026, 11, 16, 0, 1, tzinfo=MEXICO))
    assert status == 200
    assert _calls(conn, user_id) == [("ok", 2), ("rejected", 1)]
    _session(conn, user_id, tenant_id)
    usage = _json(conn.execute("SELECT public.api_usage_summary()").fetchone()[0])
    assert usage["limit"] == 1 and usage["window"] == "week"
    assert [item["status"] for item in usage["recent"]][:3] == ["ok", "rejected", "ok"]


def test_daily_quota_counts_per_user_across_tokens(conn, database_url):
    user_id, _tenant_id, *_ = _seed(conn, "premium-quota@example.com")
    first, second = _token(conn, "one")["token"], _token(conn, "two")["token"]
    conn.commit()
    at = datetime(2026, 11, 12, 23, 30, tzinfo=MEXICO)
    statuses = [_gql(database_url, token, "{ usage { used } }", at=at)[0] for token in (first, second, first, second)]
    assert statuses == [200, 200, 200, 429]
    assert _gql(database_url, second, "{ usage { used } }", at=at + timedelta(minutes=31))[0] == 200
    tokens = conn.execute(
        "SELECT COUNT(DISTINCT token_id) FROM public.api_usage_f WHERE user_id = %s", (user_id,)
    ).fetchone()[0]
    assert tokens == 2


def test_concurrent_calls_never_pass_the_limit(conn, database_url):
    _seed(conn, "race@example.com")
    token = _token(conn)["token"]
    conn.commit()
    at = datetime(2026, 11, 12, 12, 0, tzinfo=MEXICO)
    results: list[bool] = []
    barrier = threading.Barrier(12)

    def call() -> None:
        with psycopg.connect(database_url) as worker:
            barrier.wait()
            state = worker.execute(
                "SELECT public.api_consume_call_at(%s, 'graphql', %s)", (token, at)
            ).fetchone()[0]
            worker.commit()
            results.append(bool(state["ok"]))

    threads = [threading.Thread(target=call) for _ in range(12)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sorted(results) == [False] * 9 + [True] * 3


def test_consume_with_clock_is_not_granted_to_the_app_role(conn):
    conn.execute("SET ROLE strm_app")
    _expect_error(conn, "SELECT public.api_consume_call_at('x', 'graphql', NOW())", (), "permission denied")
    _expect_error(conn, "SELECT public.api_consume_call('x', 'graphql')", (), "permission denied")
    conn.execute("RESET ROLE")


# --- GraphQL ---------------------------------------------------------------------------


def test_refresh_all_is_one_call_with_selected_columns(conn, database_url):
    user_id, _tenant_id, debit_id, _ = _seed(conn, "gql@example.com")
    closed = conn.execute(
        "SELECT row_hash FROM public.master_debit_closed_f WHERE account_id = %s ORDER BY row_id LIMIT 1",
        (debit_id,),
    ).fetchone()[0]
    conn.execute("SELECT public.save_dimension(%s, 'Shop', NULL, NULL)", (closed,))
    token = _token(conn)["token"]
    conn.commit()
    status, payload, _ = _gql(database_url, token, ALL_TABS)
    assert status == 200, payload
    assert "errors" not in payload, payload["errors"]
    data = payload["data"]
    assert [len(data[key]) for key in ("debitClosed", "debitOpen", "creditClosed", "creditOpen", "creditFuture")] == [
        3, 3, 2, 2, 8,
    ]
    assert set(data["debitClosed"][0]) == {"txn_date", "concept_sk", "abonos", "cargos", "attribute_1"}
    assert set(data["debitOpen"][0]) == {"txn_date", "concept_sk", "abonos", "cargos", "amount"}
    assert "Shop" in {row["attribute_1"] for row in data["debitClosed"]}
    assert all(row["cargos"] <= 0 for row in data["debitOpen"])
    assert all(row["cargos"] >= 0 for row in data["creditOpen"])
    assert data["usage"]["used"] == 1
    assert payload["extensions"]["rows"] == 18
    assert _calls(conn, user_id) == [("ok", 1)]
    assert conn.execute(
        "SELECT rows_returned FROM public.api_usage_f WHERE user_id = %s", (user_id,)
    ).fetchone()[0] == 18


def test_months_filter_layers_and_row_cap(conn, database_url):
    _user_id, _tenant_id, *_ = _seed(conn, "gql-months@example.com")
    token = _token(conn)["token"]
    conn.execute("UPDATE public.plans_d SET api_calls_limit = 50 WHERE plan_code = 'premium'")
    conn.commit()
    try:
        # Closed rows are from 2025-10; the default (last 12 months from today) leaves them out.
        query = """{ a: movements(kind: DEBIT, layer: CLOSED) { txn_date }
                     b: movements(kind: DEBIT, layer: CLOSED, months: 120) { txn_date } }"""
        status, payload, _ = _gql(database_url, token, query)
        assert status == 200 and (len(payload["data"]["a"]), len(payload["data"]["b"])) == (0, 3)
        rows = _json(conn.execute(
            "SELECT public.graphql_rows('master_debit_closed_f', 2, NULL, '2025-11-15')"
        ).fetchone()[0])
        assert len(rows) == 3
        rows = _json(conn.execute(
            "SELECT public.graphql_rows('master_debit_closed_f', 1, NULL, '2025-11-05')"
        ).fetchone()[0])
        assert {row["txn_date"] for row in rows} == {"2025-10-07"}
        future = _json(conn.execute(
            "SELECT public.graphql_rows('master_credit_future_f', NULL, '2027-01-01')"
        ).fetchone()[0])
        assert all(row["txn_date"] > "2027-01-01" for row in future) and len(future) < 8

        status, payload, _ = _gql(database_url, token, "{ movements(kind: DEBIT, layer: FUTURE) { txn_date } }")
        assert status == 200 and "no debit future table" in payload["errors"][0]["message"]

        conn.execute("UPDATE public.plans_d SET api_max_rows = 5 WHERE plan_code = 'premium'")
        conn.commit()
        status, payload, _ = _gql(database_url, token, ALL_TABS)
        sizes = [len(payload["data"][key]) for key in ("debitClosed", "debitOpen", "creditClosed", "creditOpen")]
        assert sizes == [3, 2, 0, 0]
        assert payload["extensions"]["rows"] == 5
        assert payload["extensions"]["truncated"] == ["debitOpen", "creditClosed", "creditOpen", "creditFuture"]
        status, payload, _ = _gql(database_url, token, "{ movements(kind: CREDIT, layer: FUTURE, limit: 2) { txn_date } }")
        assert len(payload["data"]["movements"]) == 2
    finally:
        conn.execute(
            "UPDATE public.plans_d SET api_calls_limit = 3, api_max_rows = 5000 WHERE plan_code = 'premium'"
        )
        conn.commit()


def test_token_only_sees_its_own_rows(conn, database_url):
    _seed(conn, "gql-a@example.com")
    _seed(conn, "gql-b@example.com")
    token = _token(conn)["token"]
    conn.commit()
    _status, payload, _ = _gql(database_url, token, "{ movements(kind: CREDIT, layer: FUTURE) { row_hash } }")
    hashes = {row["row_hash"] for row in payload["data"]["movements"]}
    expected = {
        row[0] for row in conn.execute(
            "SELECT m.row_hash FROM public.master_credit_future_f AS m "
            "INNER JOIN cognito_users.users AS u ON u.user_id = m.user_id WHERE u.email = 'gql-b@example.com'"
        ).fetchall()
    }
    assert hashes == expected and len(hashes) == 8


@pytest.mark.parametrize(
    ("body", "status", "fragment"),
    [
        ("not json", 400, "not valid JSON"),
        (json.dumps({"query": "{ movements(kind: DEBIT, layer: OPEN) { nope } }"}), 400, "nope"),
        (json.dumps({"query": "mutation { x }"}), 400, "read-only"),
        (json.dumps({"query": "{ __schema { types { name } } }"}), 400, "Introspection"),
        (json.dumps({"query": "{ " + " ".join(f"a{i}: usage {{ used }}" for i in range(9)) + " }"}), 400, "root fields"),
        (json.dumps({"query": "{ usage { used } }", "pad": "x" * 20000}), 413, "larger than"),
        (json.dumps({"query": "{ a: usage { used } } { b: usage { used } }"}), 400, "operation"),
        (json.dumps({"query": "{ usage { used " + "used " * 300 + "} }"}), 400, "more than 250 fields"),
    ],
)
def test_request_guardrails(body, status, fragment):
    with pytest.raises(graphql_api.ApiError) as error:
        graphql_api.prepare(body)
    assert error.value.status == status
    assert fragment in error.value.message


def test_bearer_token_format():
    with pytest.raises(graphql_api.ApiError):
        graphql_api.bearer_token(None)
    with pytest.raises(graphql_api.ApiError):
        graphql_api.bearer_token("Bearer abc")
    token = "bst_" + "a" * 48
    assert graphql_api.bearer_token(f"Bearer {token}") == token


def test_window_bounds_use_mexico_city_calendar(conn):
    bounds = conn.execute(
        "SELECT window_start, window_end FROM public.api_window_bounds('day', %s)",
        (datetime(2026, 11, 12, 23, 30, tzinfo=MEXICO),),
    ).fetchone()
    assert bounds == (datetime(2026, 11, 12, tzinfo=MEXICO), datetime(2026, 11, 13, tzinfo=MEXICO))
    bounds = conn.execute(
        "SELECT window_start, window_end FROM public.api_window_bounds('week', %s)",
        (datetime(2026, 11, 15, 23, 59, tzinfo=MEXICO),),
    ).fetchone()
    assert bounds == (datetime(2026, 11, 9, tzinfo=MEXICO), datetime(2026, 11, 16, tzinfo=MEXICO))
    assert date(2026, 11, 9).weekday() == 0


def test_apps_script_query_runs_against_the_database(conn, database_url):
    from test_graphql_node import NODE, _apps_script

    if NODE is None:
        pytest.skip("node not installed")
    _seed(conn, "sheets@example.com", plan="free")
    token = _token(conn)["token"]
    conn.commit()
    built = _apps_script({}, 200, "console.log(JSON.stringify(vm.runInContext('buildQuery(DEFAULT_TABS)', context)));")
    body = json.dumps({"query": built["query"], "operationName": "RefreshAll"})
    with psycopg.connect(database_url) as db:
        status, payload, _ = graphql_api.handle(db, f"Bearer {token}", body)
    assert status == 200 and "errors" not in payload, payload
    # Closed tabs default to the last 12 months: the 2025 fixture rows fall outside.
    assert [len(payload["data"][f"t{i}"]) for i in range(6)] == [0, 2, 0, 3, 8, 0]
    assert set(payload["data"]["t1"][0]) == set(built["plan"][1]["columns"])
    assert payload["data"]["usage"]["remaining"] == 0
