from __future__ import annotations

import getpass
import json
import re
import subprocess
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

from postgres_ops import apply_banking_ddl, split_sql
from statements.curated import curated_put_params
from statements.rules import (
    catcher_periods,
    concept_sk,
    decode_bank_csv,
    movement_row_hash,
    normalize_header,
    period_bounds,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
SQL_TEST = REPO_ROOT / "sql" / "tests" / "statement_flow.sql"
OWNER_SAMPLES = Path("/home/ubuntu/.cursor/projects/workspace/uploads")
AS_OF = date(2026, 10, 20)

DEBIT_CSV = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "07/10/2025,PAYPAL *SHOP 150323,-99.0,0.0,172.83\n"
    "03/10/2025,I.V.A 01-OCT-25,-28.8,0.0,291.2\n"
    "03/10/2025,DEPOSITO CUENTA 0639,0.0,500.0,500.0\n"
)
CREDIT_CSV = (
    "Fecha,Concepto,Abono,Cargo,Tarjeta\r\n"
    "19/10/2025,MICROSOFT 001 Referencia ,0,20.00,Titular ***3978\r\n"
    "19/10/2025,MICROSOFT 001 Referencia ,0,20.00,Titular ***3978\r\n"
)
PLAN_CSV = (
    "Fecha de operaci\u00f3n,Tasa anual,Importe inicial,Importe pendiente,"
    "Concepto,Pagos pendientes,Mensualidad\r\n"
    "15/10/2025,0.0000%,2392.00,2392.00,MI ATT APP, 03/03,797.33\r\n"
)


def _role_name() -> str:
    user = getpass.getuser()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", user):
        raise RuntimeError(f"Unsupported database role name {user}")
    return user


def _ensure_login_role() -> None:
    user = _role_name()
    statement = (
        "DO $$ BEGIN "
        f"IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{user}') THEN "
        f"CREATE ROLE {user} SUPERUSER LOGIN; "
        "END IF; END $$;"
    )
    subprocess.run(
        ["sudo", "-u", "postgres", "psql", "-v", "ON_ERROR_STOP=1", "-c", statement],
        check=True,
        capture_output=True,
        text=True,
    )


def _admin():
    return psycopg.connect("dbname=postgres", autocommit=True)


@pytest.fixture(scope="module")
def database_url():
    _ensure_login_role()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin = _admin()
    admin.execute(f'CREATE DATABASE "{name}"')
    admin.close()
    url = f"postgresql:///{name}?sslmode=disable"
    apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
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


def _json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


def _expect_error(conn, sql, params, fragment, sqlstate=None):
    with conn.cursor() as cur:
        cur.execute("SAVEPOINT probe")
        try:
            cur.execute(sql, params)
        except psycopg.Error as exc:
            cur.execute("ROLLBACK TO SAVEPOINT probe")
            assert fragment in str(exc)
            if sqlstate is not None:
                assert exc.sqlstate == sqlstate
            return
    raise AssertionError(f"expected an error containing {fragment}")


def _user(conn, email):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO cognito_users.users (cognito_sub, email)
            VALUES (%s, %s)
            RETURNING user_id
            """,
            (email, email),
        )
        user_id = cur.fetchone()[0]
        cur.execute("SELECT public.ensure_personal_tenant(%s)", (user_id,))
        tenant_id = cur.fetchone()[0]
    return user_id, tenant_id


def _session(conn, user_id, tenant_id):
    conn.execute("SELECT set_config('app.user_id', %s, false)", (str(user_id),))
    conn.execute("SELECT set_config('app.tenant_id', %s, false)", (str(tenant_id),))


def _banorte(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT bank_id FROM public.banks_d WHERE LOWER(bank_name) = 'banorte'")
        return cur.fetchone()[0]


def _type_id(conn, name):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT a_type_id FROM public.account_types_d WHERE LOWER(type_name) = LOWER(%s)",
            (name,),
        )
        return cur.fetchone()[0]


def _create(conn, type_name, account_name, account_number, cutoff=None, credit_days=None, as_of=AS_OF):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.create_bank_account(%s, %s, %s, %s, %s, %s, %s)",
            (
                _banorte(conn),
                _type_id(conn, type_name),
                account_name,
                account_number,
                cutoff,
                credit_days,
                as_of,
            ),
        )
        return cur.fetchone()[0]


def _home(conn, as_of=AS_OF):
    with conn.cursor() as cur:
        cur.execute("SELECT public.statement_home(%s)", (as_of,))
        return _json(cur.fetchone()[0])


def _period(conn, account_id, label, as_of=AS_OF):
    home = _home(conn, as_of)
    account = next(item for item in home["accounts"] if item["account_id"] == account_id)
    return next(item for item in account["periods"] if item["period_label"] == label)


def _ingest(conn, account_id, cutoff_id, slot, filename, csv_text, as_of=AS_OF):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.ingest_statement_csv(%s, %s, %s, %s, %s, %s)",
            (account_id, cutoff_id, slot, filename, csv_text, as_of),
        )
        return _json(cur.fetchone()[0])


def test_headers_periods_and_hash_match_sql(conn):
    assert normalize_header("Fecha de operaci\u00f3n") == "fecha de operacion"
    assert normalize_header("  Cargos\u00a0") == "cargos"
    assert concept_sk("  PAYPAL *SHOP 150323 ") == "150323"
    assert concept_sk("I.V.A") == "IVA"
    assert concept_sk("***") == ""
    start, end = period_bounds(allows_cutoff=True, cutoff_day=6, year=2026, month=10)
    assert (start, end) == (date(2026, 9, 7), date(2026, 10, 6))
    feb_start, feb_end = period_bounds(allows_cutoff=True, cutoff_day=31, year=2024, month=2)
    assert feb_end == date(2024, 2, 29)
    assert feb_start == date(2024, 2, 1)
    assert period_bounds(allows_cutoff=False, cutoff_day=None, year=2026, month=9) == (
        date(2026, 9, 1),
        date(2026, 9, 30),
    )
    assert catcher_periods(allows_cutoff=True, cutoff_day=6, as_of=AS_OF) == [
        (date(2026, 7, 7), date(2026, 8, 6)),
        (date(2026, 8, 7), date(2026, 9, 6)),
        (date(2026, 9, 7), date(2026, 10, 6)),
    ]
    assert catcher_periods(allows_cutoff=False, cutoff_day=None, as_of=AS_OF) == [
        (date(2026, 7, 1), date(2026, 7, 31)),
        (date(2026, 8, 1), date(2026, 8, 31)),
        (date(2026, 9, 1), date(2026, 9, 30)),
    ]
    digest = movement_row_hash(date(2026, 9, 26), "0639", Decimal("-49"), "4275", 1)
    with conn.cursor() as cur:
        cur.execute("SELECT public.normalize_header(%s)", ("Fecha de operaci\u00f3n",))
        assert cur.fetchone()[0] == "fecha de operacion"
        cur.execute("SELECT public.concept_sk(%s), public.concept_sk(%s)", ("I.V.A", "  SPEI 123-45 "))
        assert cur.fetchone() == ("IVA", "12345")
        cur.execute(
            "SELECT public.movement_row_hash(%s, %s, %s, %s, %s)",
            (date(2026, 9, 26), "0639", Decimal("-49"), "4275", 1),
        )
        assert cur.fetchone()[0] == digest
        cur.execute(
            "SELECT public.movement_row_hash(%s, %s, %s, %s, %s)",
            (date(2026, 9, 26), "639", Decimal("-49"), "4275", 1),
        )
        assert cur.fetchone()[0] != digest
        cur.execute(
            """
            SELECT period_start, period_end
            FROM public.catcher_periods(TRUE, 6, %s)
            ORDER BY period_end
            """,
            (AS_OF,),
        )
        assert cur.fetchall() == catcher_periods(allows_cutoff=True, cutoff_day=6, as_of=AS_OF)


def test_sample_shapes_load_and_keep_account_text(conn):
    user_id, tenant_id = _user(conn, "samples@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    credit_id = _create(conn, "bank credit card", "Credit", "3978", 6, 20)
    home = _home(conn)
    debit = next(item for item in home["accounts"] if item["account_number"] == "0639")
    credit = next(item for item in home["accounts"] if item["account_number"] == "3978")
    assert [item["period_label"] for item in debit["periods"]] == ["2026-07", "2026-08", "2026-09"]
    assert [item["period_label"] for item in credit["periods"]] == ["2026-08", "2026-09", "2026-10"]
    assert credit["periods"][-1]["payment_due"] == "2026-10-26"
    assert debit["periods"][-1]["show_statement_slot"] is True
    assert debit["periods"][-1]["show_installment_slot"] is False
    assert credit["periods"][-1]["show_installment_slot"] is True
    assert all(item["pending"] for item in debit["periods"])

    debit_period = debit["periods"][-1]["cutoff_id"]
    credit_period = credit["periods"][-1]["cutoff_id"]
    loaded = _ingest(conn, debit_id, debit_period, "statement", "0639.csv", DEBIT_CSV)
    assert loaded["row_count"] == 3
    monthly = _ingest(conn, credit_id, credit_period, "statement", "3978.csv", CREDIT_CSV)
    assert monthly["row_count"] == 2
    plan = _ingest(conn, credit_id, credit_period, "installment", "msi.csv", PLAN_CSV)
    assert plan["row_count"] == 1

    stored_number = conn.execute(
        "SELECT account_number FROM public.bank_accounts_d WHERE account_id = %s",
        (debit_id,),
    ).fetchone()[0]
    assert stored_number == "0639"
    debit_rows = conn.execute(
        """
        SELECT concept_sk, cargos, abonos, saldos, amount, account_number
        FROM public.master_debit_closed_f
        ORDER BY txn_date, concept_sk
        """
    ).fetchall()
    paypal = next(row for row in debit_rows if row[0] == "150323")
    assert paypal[1] == Decimal("-99.00")
    assert paypal[3] == Decimal("172.83")
    assert all(row[5] == "0639" for row in debit_rows)
    occurrences = conn.execute(
        """
        SELECT occurrence, amount, concept_sk
        FROM public.master_credit_closed_f
        ORDER BY occurrence
        """
    ).fetchall()
    assert occurrences == [(1, Decimal("20.00"), "001"), (2, Decimal("20.00"), "001")]
    assert conn.execute(
        "SELECT COUNT(DISTINCT row_hash) FROM public.master_credit_closed_f"
    ).fetchone()[0] == 2
    plan_row = conn.execute(
        """
        SELECT tasa_anual, pagos_pendientes, mensualidad, amount, account_number
        FROM public.credit_plan_closed_f
        """
    ).fetchone()
    assert plan_row == (Decimal("0.0000"), "03/03", Decimal("797.33"), Decimal("797.33"), "3978")
    assert conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0] == 6
    home = _home(conn)
    credit = next(item for item in home["accounts"] if item["account_id"] == credit_id)
    latest = credit["periods"][-1]
    assert latest["pending"] is False
    assert latest["statement_row_count"] == 2
    assert latest["installment_row_count"] == 1
    assert latest["show_statement_slot"] is False


def test_duplicate_file_and_bad_header_store_nothing(conn):
    user_id, tenant_id = _user(conn, "dedup@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    period = _period(conn, debit_id, "2026-09")
    _ingest(conn, debit_id, period["cutoff_id"], "statement", "first.csv", DEBIT_CSV)
    older = _period(conn, debit_id, "2026-08")
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'again.csv', %s, %s)",
        (debit_id, older["cutoff_id"], DEBIT_CSV, AS_OF),
        "already uploaded",
        "23505",
    )
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'bad.csv', %s, %s)",
        (debit_id, older["cutoff_id"], "foo,bar\n1,2\n", AS_OF),
        "do not match a Banorte",
        "22P02",
    )
    assert conn.execute(
        "SELECT COUNT(*) FROM public.master_debit_closed_f WHERE account_id = %s",
        (debit_id,),
    ).fetchone()[0] == 3
    assert conn.execute(
        "SELECT COUNT(*) FROM public.statement_uploads_f WHERE account_id = %s",
        (debit_id,),
    ).fetchone()[0] == 1


def test_whole_file_delete_keeps_dimensions(conn):
    user_id, tenant_id = _user(conn, "delete@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    period = _period(conn, debit_id, "2026-09")
    loaded = _ingest(conn, debit_id, period["cutoff_id"], "statement", "0639.csv", DEBIT_CSV)
    _expect_error(
        conn,
        "DELETE FROM public.master_debit_closed_f WHERE file_id = %s",
        (loaded["file_id"],),
        "only the whole uploaded file can be deleted",
        "42501",
    )
    _expect_error(
        conn,
        "UPDATE public.master_debit_closed_f SET concept = concept WHERE file_id = %s",
        (loaded["file_id"],),
        "append-only",
        "42501",
    )
    conn.execute("SELECT public.delete_statement_upload(%s)", (loaded["file_id"],))
    assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM public.statement_uploads_f").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0] == 3
    home = _home(conn)
    latest = next(item for item in home["accounts"] if item["account_id"] == debit_id)["periods"][-1]
    assert latest["pending"] is True
    assert latest["show_statement_slot"] is True


def test_earlier_period_can_be_removed_only_when_empty(conn):
    user_id, tenant_id = _user(conn, "periods@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    cutoff_id = conn.execute(
        "SELECT public.add_earlier_period(%s, %s)",
        (debit_id, AS_OF),
    ).fetchone()[0]
    added = conn.execute(
        """
        SELECT period_start, period_end, added_by_user
        FROM public.cutoff_date_f
        WHERE cutoff_id = %s
        """,
        (cutoff_id,),
    ).fetchone()
    assert added == (date(2026, 6, 1), date(2026, 6, 30), True)
    window = _period(conn, debit_id, "2026-09")
    _expect_error(
        conn,
        "SELECT public.remove_statement_period(%s, %s)",
        (window["cutoff_id"], AS_OF),
        "current download periods stay",
        "22023",
    )
    _ingest(conn, debit_id, cutoff_id, "statement", "june.csv", DEBIT_CSV)
    _expect_error(
        conn,
        "SELECT public.remove_statement_period(%s, %s)",
        (cutoff_id, AS_OF),
        "Delete the uploaded file",
        "23503",
    )
    file_id = conn.execute(
        "SELECT upload_id FROM public.statement_uploads_f WHERE cutoff_id = %s",
        (cutoff_id,),
    ).fetchone()[0]
    conn.execute("SELECT public.delete_statement_upload(%s)", (file_id,))
    conn.execute("SELECT public.remove_statement_period(%s, %s)", (cutoff_id, AS_OF))
    assert conn.execute(
        "SELECT COUNT(*) FROM public.cutoff_date_f WHERE cutoff_id = %s",
        (cutoff_id,),
    ).fetchone()[0] == 0


def test_plan_limits_and_banorte_only(conn):
    user_id, tenant_id = _user(conn, "plans@example.com")
    _session(conn, user_id, tenant_id)
    other = conn.execute(
        "INSERT INTO public.banks_d (bank_name) VALUES ('Other bank') RETURNING bank_id"
    ).fetchone()[0]
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Nope', '9999', NULL, NULL, %s)",
        (other, _type_id(conn, "bank debit"), AS_OF),
        "Only Banorte is supported for now",
        "23514",
    )
    _create(conn, "bank debit", "Debit", "0639")
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Second', '1111', NULL, NULL, %s)",
        (_banorte(conn), _type_id(conn, "bank debit"), AS_OF),
        "Free allows 1 debit account",
        "23514",
    )
    _create(conn, "bank credit card", "Credit", "3978", 6, 20)
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Extra', '2222', 6, 20, %s)",
        (_banorte(conn), _type_id(conn, "bank credit card"), AS_OF),
        "Free allows 1 credit account",
        "23514",
    )
    conn.execute("UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s", (tenant_id,))
    for number in range(2, 10):
        kind = "bank debit" if number % 2 == 0 else "bank credit card"
        cutoff = None if kind == "bank debit" else 6
        days = None if kind == "bank debit" else 20
        _create(conn, kind, f"Account {number}", f"{number:04d}", cutoff, days)
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Eleventh', '0011', NULL, NULL, %s)",
        (_banorte(conn), _type_id(conn, "savings"), AS_OF),
        "private deployment",
        "23514",
    )


def test_open_reload_does_not_touch_closed_or_dimensions(conn):
    user_id, tenant_id = _user(conn, "open@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    period = _period(conn, debit_id, "2026-09")
    _ingest(conn, debit_id, period["cutoff_id"], "statement", "0639.csv", DEBIT_CSV)
    before = conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0]
    conn.execute(
        "SELECT public.reload_open_movements(%s::jsonb)",
        (
            json.dumps(
                {
                    "debit": [
                        {
                            "account_number": "0639",
                            "txn_date": "2026-10-02",
                            "concept": "OPEN 77",
                            "cargos": -10,
                            "abonos": 0,
                            "saldos": 90,
                        }
                    ]
                }
            ),
        ),
    )
    assert conn.execute("SELECT COUNT(*) FROM public.open_debit_f").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 3
    conn.execute("SELECT public.reload_open_movements('{}'::jsonb)")
    assert conn.execute("SELECT COUNT(*) FROM public.open_debit_f").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 3
    assert conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0] == before + 1


def test_row_level_security_hides_other_tenants(conn):
    owner, owner_tenant = _user(conn, "owner@example.com")
    other, other_tenant = _user(conn, "other@example.com")
    _session(conn, owner, owner_tenant)
    _create(conn, "bank debit", "Payroll", "0639")
    _session(conn, other, other_tenant)
    conn.execute("SET ROLE strm_app")
    assert conn.execute("SELECT account_name FROM public.bank_accounts_d").fetchall() == []
    assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 0
    conn.execute("RESET ROLE")
    _session(conn, owner, owner_tenant)
    conn.execute("SET ROLE strm_app")
    visible = conn.execute(
        "SELECT account_number FROM public.bank_accounts_d ORDER BY account_number"
    ).fetchall()
    assert visible == [("0639",)]
    conn.execute("RESET ROLE")


def test_banking_ddl_applies_twice_without_dropping_rows(database_url):
    with psycopg.connect(database_url) as conn:
        user_id, tenant_id = _user(conn, "twice@example.com")
        _session(conn, user_id, tenant_id)
        debit_id = _create(conn, "bank debit", "Debit", "0639")
        period = _period(conn, debit_id, "2026-09")
        _ingest(conn, debit_id, period["cutoff_id"], "statement", "0639.csv", DEBIT_CSV)
        conn.commit()
    again = apply_banking_ddl(database_url, users_schema="cognito_users", database="neondb")
    assert "006_statement_flow.sql" in again
    with psycopg.connect(database_url) as conn:
        assert conn.execute("SELECT COUNT(*) FROM public.account_types_d").fetchone()[0] == 3
        assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 3


def test_sql_script(database_url):
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin = _admin()
    admin.execute(f'CREATE DATABASE "{name}"')
    admin.close()
    url = f"postgresql:///{name}?sslmode=disable"
    try:
        apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
        script = SQL_TEST.read_text(encoding="utf-8")
        with psycopg.connect(url) as conn:
            for statement in split_sql(script):
                conn.execute(statement)
            conn.commit()
    finally:
        admin = _admin()
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.close()


def test_owner_samples_when_present(conn):
    names = {
        "debit": "01M5E2Y0BW8M83ZKN8ZA5CKHRG_4eb5.csv",
        "monthly": "01M5E2Y1NEVXESXHT2M985W4KE_b1b0.csv",
        "plan": "01M5E2Y0V3X9QA08BQA0SGWT9M_8bce.csv",
    }
    paths = {key: OWNER_SAMPLES / name for key, name in names.items()}
    if not all(path.exists() for path in paths.values()):
        pytest.skip("owner sample CSVs are not on this machine")
    user_id, tenant_id = _user(conn, "owner-samples@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    credit_id = _create(conn, "bank credit card", "Credit", "3978", 6, 20)
    debit_period = _period(conn, debit_id, "2026-09")["cutoff_id"]
    credit_period = _period(conn, credit_id, "2026-10")["cutoff_id"]
    debit_text = decode_bank_csv(paths["debit"].read_bytes())
    monthly_text = decode_bank_csv(paths["monthly"].read_bytes())
    plan_text = decode_bank_csv(paths["plan"].read_bytes())
    assert "operación" in plan_text or "operacion" in normalize_header(plan_text.splitlines()[0])
    assert _ingest(conn, debit_id, debit_period, "statement", names["debit"], debit_text)["row_count"] == 11
    assert _ingest(conn, credit_id, credit_period, "statement", names["monthly"], monthly_text)["row_count"] == 31
    assert _ingest(conn, credit_id, credit_period, "installment", names["plan"], plan_text)["row_count"] == 1
    pagos = conn.execute("SELECT pagos_pendientes FROM public.credit_plan_closed_f").fetchone()[0]
    assert pagos == "03/03"


def test_curated_put_is_write_once_and_locked():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    params = curated_put_params(
        bucket="curated-bucket",
        tenant_id="tenant-1",
        upload_id="upload-1",
        body=b"date,concept\n",
        now=now,
    )
    assert params["Key"] == "curated/tenant-1/upload-1.csv"
    assert params["IfNoneMatch"] == "*"
    assert params["ObjectLockMode"] == "GOVERNANCE"
    assert params["ObjectLockRetainUntilDate"] == datetime(2027, 10, 21, tzinfo=timezone.utc)


def test_split_sql_keeps_function_bodies():
    parts = split_sql(
        "CREATE FUNCTION f() RETURNS void AS $fn$\nBEGIN\n  PERFORM 1;\nEND\n$fn$;\nSELECT 1;\n-- tail\n"
    )
    assert len(parts) == 2
    assert "PERFORM 1;" in parts[0]
    assert parts[1] == "SELECT 1"
