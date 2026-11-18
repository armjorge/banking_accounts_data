from __future__ import annotations

import base64
import getpass
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from itertools import pairwise
from pathlib import Path

import psycopg
import pytest

from postgres_ops import _apply_files, apply_banking_ddl, split_sql
from statements.curated import (
    backup_object_key,
    curated_put_params,
    legacy_object_key,
    manifest_key,
    metadata_value,
    standard_object_key,
)
from statements.rules import (
    catcher_periods,
    concept_sk,
    current_period,
    decode_bank_csv,
    future_cutoff_periods,
    installment_counts,
    movement_row_hash,
    movement_row_hash_v2,
    normalize_header,
    period_bounds,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
SQL_TEST = REPO_ROOT / "sql" / "tests" / "statement_flow.sql"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
# Applied by hand on Neon after 006/007 (apply_banking_ddl). 009 clears statement data,
# so a re-apply on a database with rows skips it.
LATER_MIGRATIONS = (
    "008_bbva_header_mapping.sql",
    "009_clear_and_open_by_account.sql",
    "010_bbva_xlsx_csv_ingest.sql",
    "011_open_future_ledgers.sql",
    "012_edit_credit_cutoff.sql",
    "013_chosen_names_vault_keys.sql",
    "014_normalized_row_hash.sql",
    "015_dimensions_api.sql",
    "016_lists_completeness_transfers.sql",
    "017_investments_assets.sql",
    "018_standard_masters_balances_banks.sql",
    "019_account_types_open_assets.sql",
    "020_statement_home_asset_accounts.sql",
    "021_delete_account.sql",
    "024_drop_asset_only_columns.sql",
)
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


def _psql(statement: str) -> None:
    """Run SQL as the local superuser. Homebrew Postgres has no `postgres` OS user."""
    command = ["psql", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", statement]
    try:
        subprocess.run(
            ["sudo", "-u", "postgres", *command],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        subprocess.run(command, check=True, capture_output=True, text=True)


def _ensure_login_role() -> None:
    user = _role_name()
    _psql(
        "DO $$ BEGIN "
        f"IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{user}') THEN "
        f"CREATE ROLE {user} SUPERUSER LOGIN; "
        "END IF; END $$;"
    )


def _apply_all_ddl(url, *, skip_clear=False):
    applied = apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
    names = tuple(
        name for name in LATER_MIGRATIONS if not (skip_clear and name.startswith("009_"))
    )
    applied.extend(
        _apply_files(
            url,
            names,
            users_schema="cognito_users",
            database="neondb",
            app_schema="public",
        )
    )
    return applied


def _admin():
    try:
        return psycopg.connect("dbname=postgres user=postgres", autocommit=True)
    except psycopg.Error:
        return psycopg.connect("dbname=postgres", autocommit=True)


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


def _v2(conn, account_id, txn_date, sk, abonos, cargos, occurrence):
    """Expected sql/014 row_hash for a row of this account (Python mirror)."""
    user_id, bank_id = conn.execute(
        "SELECT user_id::text, bank_id FROM public.bank_accounts_d WHERE account_id = %s", (account_id,)
    ).fetchone()
    return movement_row_hash_v2(user_id, account_id, bank_id, txn_date, sk, abonos, cargos, occurrence)


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
    # Closed window (latest closed + the two before it) plus the current period.
    assert [item["period_label"] for item in debit["periods"]] == [
        "2026-07",
        "2026-08",
        "2026-09",
        "2026-10",
    ]
    assert [item["period_label"] for item in credit["periods"]] == [
        "2026-08",
        "2026-09",
        "2026-10",
        "2026-11",
    ]
    assert [item["is_current"] for item in debit["periods"]] == [False, False, False, True]
    latest_debit = _period(conn, debit_id, "2026-09")
    latest_credit = _period(conn, credit_id, "2026-10")
    assert latest_credit["payment_due"] == "2026-10-26"
    assert latest_debit["show_statement_slot"] is True
    assert latest_debit["show_installment_slot"] is False
    assert latest_credit["show_installment_slot"] is True
    assert all(item["pending"] for item in debit["periods"])

    debit_period = latest_debit["cutoff_id"]
    credit_period = latest_credit["cutoff_id"]
    loaded = _ingest(conn, debit_id, debit_period, "statement", "0639.csv", DEBIT_CSV)
    assert loaded["row_count"] == 3
    assert loaded["ledger_state"] == "closed"
    monthly = _ingest(conn, credit_id, credit_period, "statement", "3978.csv", CREDIT_CSV)
    assert monthly["row_count"] == 2
    plan = _ingest(conn, credit_id, credit_period, "installment", "msi.csv", PLAN_CSV)
    # " 03/03" = 3 payments still due -> next three cutoffs after 2026-10-20 (day 6).
    assert plan["source_row_count"] == 1
    assert plan["row_count"] == 3
    assert plan["ledger_state"] == "future"

    stored_number = conn.execute(
        "SELECT account_number FROM public.bank_accounts_d WHERE account_id = %s",
        (debit_id,),
    ).fetchone()[0]
    assert stored_number == "0639"
    debit_rows = conn.execute(
        """
        SELECT concept_sk, cargos, abonos, amount, account_number
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_debit_closed_f') AS m
        ORDER BY txn_date, concept_sk
        """
    ).fetchall()
    paypal = next(row for row in debit_rows if row[0] == "150323")
    # Debit cargos stay negative; amount = abonos + cargos.
    assert paypal[1] == Decimal("-99.00")
    assert paypal[3] == Decimal("-99.00")
    assert all(row[4] == "0639" for row in debit_rows)
    occurrences = conn.execute(
        """
        SELECT occurrence, amount, concept_sk
        FROM public.master_credit_closed_f
        ORDER BY occurrence
        """
    ).fetchall()
    assert occurrences == [(1, Decimal("-20.00"), "001"), (2, Decimal("-20.00"), "001")]
    assert conn.execute(
        "SELECT COUNT(DISTINCT row_hash) FROM public.master_credit_closed_f"
    ).fetchone()[0] == 2
    assert conn.execute("SELECT COUNT(*) FROM public.credit_plan_closed_f").fetchone()[0] == 0
    future_rows = conn.execute(
        """
        SELECT txn_date, period_start, period_end, cargos, abonos, amount, account_number
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_credit_future_f') AS m
        ORDER BY txn_date
        """
    ).fetchall()
    assert future_rows == [
        (date(2026, 11, 6), date(2026, 10, 7), date(2026, 11, 6), Decimal("797.33"), Decimal("0.00"),
         Decimal("-797.33"), "3978"),
        (date(2026, 12, 6), date(2026, 11, 7), date(2026, 12, 6), Decimal("797.33"), Decimal("0.00"),
         Decimal("-797.33"), "3978"),
        # The last payment absorbs the rounding gap so the plan sums to importe pendiente.
        (date(2027, 1, 6), date(2026, 12, 7), date(2027, 1, 6), Decimal("797.34"), Decimal("0.00"),
         Decimal("-797.34"), "3978"),
    ]
    assert conn.execute("SELECT (SELECT COUNT(*) FROM public.debit_d) + (SELECT COUNT(*) FROM public.credit_d)").fetchone()[0] == 8
    home = _home(conn)
    credit = next(item for item in home["accounts"] if item["account_id"] == credit_id)
    latest = next(item for item in credit["periods"] if item["period_label"] == "2026-10")
    assert latest["pending"] is False
    assert latest["statement_row_count"] == 2
    assert latest["installment_row_count"] == 3
    assert latest["installment_ledger_state"] == "future"
    assert latest["show_statement_slot"] is False
    assert credit["future_row_count"] == 3


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
        "do not match a supported statement profile",
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
    assert conn.execute("SELECT COUNT(*) FROM public.debit_d").fetchone()[0] == 3
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
    # sql/018: a bank without a built-in profile can hold accounts (the column map parses them).
    conn.execute(
        "SELECT public.create_bank_account(%s, %s, 'Other', '9999', NULL, NULL, %s)",
        (other, _type_id(conn, "bank debit"), AS_OF),
    )
    conn.execute("DELETE FROM public.cutoff_date_f WHERE account_id IN "
                 "(SELECT account_id FROM public.bank_accounts_d WHERE account_number = '9999')")
    conn.execute("DELETE FROM public.bank_accounts_d WHERE account_number = '9999'")
    _create(conn, "bank debit", "Debit", "0639")
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Second', '1111', NULL, NULL, %s)",
        (_banorte(conn), _type_id(conn, "bank debit"), AS_OF),
        "Free plan allows at most 1 debit account",
        "23514",
    )
    _create(conn, "bank credit card", "Credit", "3978", 6, 20)
    _expect_error(
        conn,
        "SELECT public.create_bank_account(%s, %s, 'Extra', '2222', 6, 20, %s)",
        (_banorte(conn), _type_id(conn, "bank credit card"), AS_OF),
        "Free plan allows at most 1 credit account",
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
        (_banorte(conn), _type_id(conn, "bank debit"), AS_OF),
        "account(s) in total",
        "23514",
    )


def test_legacy_open_reload_is_gone(conn):
    assert conn.execute(
        """
        SELECT COUNT(*)
        FROM pg_proc
        WHERE proname IN (
            'reload_open_movements', 'replace_open_account_movements', 'truncate_open_movements'
        )
        """
    ).fetchone()[0] == 0


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
    again = _apply_all_ddl(database_url, skip_clear=True)
    # sql/018: on the standard layout 006-017 are not run again; 018 re-applies them.
    assert "006_statement_flow.sql" not in again
    assert "011_open_future_ledgers.sql" not in again
    assert "018_standard_masters_balances_banks.sql" in again
    with psycopg.connect(database_url) as conn:
        # Bank credit card, Bank debit, and one asset type (sql/019).
        assert conn.execute("SELECT COUNT(*) FROM public.account_types_d").fetchone()[0] == 3
        assert conn.execute(
            "SELECT COUNT(*) FROM public.account_types_d WHERE ledger_kind <> 'asset'"
        ).fetchone()[0] == 2
        assert conn.execute("SELECT COUNT(*) FROM public.master_debit_closed_f").fetchone()[0] == 3


def test_sql_script(database_url):
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin = _admin()
    admin.execute(f'CREATE DATABASE "{name}"')
    admin.close()
    url = f"postgresql:///{name}?sslmode=disable"
    try:
        _apply_all_ddl(url)
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
    plan = _ingest(conn, credit_id, credit_period, "installment", names["plan"], plan_text)
    assert plan["source_row_count"] == 1
    assert plan["row_count"] == 3
    assert conn.execute("SELECT COUNT(*) FROM public.master_credit_future_f").fetchone()[0] == 3


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


# --- Bank Stream: open (current period) and future (installment) ledgers, sql/011 ---------

MSI_FIXTURE = FIXTURES / "banorte_msi_future_cp1252.csv"
MSI_AS_OF = date(2026, 11, 11)
OPEN_DEBIT_CSV = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "03/11/2026,SPEI ENVIADO 4411,-250.0,0.0,750.0\n"
    "05/11/2026,DEPOSITO NOMINA 0639,0.0,1000.0,1750.0\n"
    "05/11/2026,COMISION 77,-5.0,0.0,1745.0\n"
)
OPEN_DEBIT_CSV_SMALLER = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "03/11/2026,SPEI ENVIADO 4411,-250.0,0.0,750.0\n"
)
OPEN_CREDIT_CSV = (
    "Fecha,Concepto,Abono,Cargo,Tarjeta\r\n"
    "08/11/2026,OXXO 123 Referencia ,0,85.50,Titular ***3978\r\n"
    "09/11/2026,PAGO 456 Referencia ,500.00,0,Titular ***3978\r\n"
)


def _premium(conn, tenant_id):
    conn.execute("UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s", (tenant_id,))


def _current(conn, account_id, as_of):
    account = next(item for item in _home(conn, as_of)["accounts"] if item["account_id"] == account_id)
    return next(item for item in account["periods"] if item["is_current"])


def _msi_text():
    raw = MSI_FIXTURE.read_bytes()
    assert b"\r\n" in raw
    assert "operación".encode("cp1252") in raw
    return decode_bank_csv(raw)


def _count(conn, table, account_id):
    return conn.execute(
        f"SELECT COUNT(*) FROM public.{table} WHERE account_id = %s",
        (account_id,),
    ).fetchone()[0]


def test_period_helpers_match_python_mirror(conn):
    cases = [
        (False, None, date(2026, 11, 11)),
        (True, 6, date(2026, 11, 11)),
        (True, 20, date(2026, 11, 11)),
        (True, 11, date(2026, 11, 11)),
        (True, 31, date(2027, 2, 15)),
        (True, 6, date(2026, 12, 31)),
    ]
    for allows, day, as_of in cases:
        sql_current = conn.execute(
            "SELECT period_start, period_end FROM public.current_period(%s, %s, %s)",
            (allows, day, as_of),
        ).fetchone()
        assert sql_current == current_period(allows_cutoff=allows, cutoff_day=day, as_of=as_of)
        assert sql_current[0] <= as_of <= sql_current[1]
        if allows:
            sql_future = conn.execute(
                """
                SELECT period_start, period_end
                FROM public.future_cutoff_periods(%s, %s, 4)
                ORDER BY payment_no
                """,
                (day, as_of),
            ).fetchall()
            assert sql_future == future_cutoff_periods(cutoff_day=day, as_of=as_of, count=4)
            assert all(end > as_of for _, end in sql_future)
    assert current_period(allows_cutoff=False, cutoff_day=None, as_of=MSI_AS_OF) == (
        date(2026, 11, 1),
        date(2026, 11, 30),
    )
    # Credit current window starts the day after the last closed cutoff.
    assert current_period(allows_cutoff=True, cutoff_day=6, as_of=MSI_AS_OF) == (
        date(2026, 11, 7),
        date(2026, 12, 6),
    )
    # A cutoff on the as-of day is not "after" it.
    assert future_cutoff_periods(cutoff_day=11, as_of=MSI_AS_OF, count=1) == [
        (date(2026, 11, 12), date(2026, 12, 11)),
    ]
    assert installment_counts(" 02/03") == (2, 3)
    assert conn.execute(
        "SELECT public.installment_remaining(' 05/12'), public.installment_total(' 05/12')"
    ).fetchone() == (5, 12)


def test_banorte_msi_fixture_expands_to_future_cutoffs(conn):
    user_id, tenant_id = _user(conn, "msi@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _create(conn, "bank credit card", "Credit", "3978", 6, 20, as_of=MSI_AS_OF)
    current = _current(conn, credit_id, MSI_AS_OF)
    assert (current["period_start"], current["period_end"]) == ("2026-11-07", "2026-12-06")
    assert current["show_installment_slot"] is True
    loaded = _ingest(conn, credit_id, current["cutoff_id"], "installment", "msi.csv", _msi_text(), MSI_AS_OF)
    assert loaded["source_row_count"] == 3
    assert loaded["row_count"] == 8
    assert loaded["target_table"] == "master_credit_future_f"

    rows = conn.execute(
        """
        SELECT txn_date, period_start, period_end, concept_sk, cargos, abonos, amount, occurrence, row_hash
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_credit_future_f') AS m
        WHERE account_id = %s
        ORDER BY concept_sk, txn_date
        """,
        (credit_id,),
    ).fetchall()
    by_plan: dict[str, list[date]] = {}
    for txn_date, start, end, sk, cargo, abono, amount, occurrence, _ in rows:
        by_plan.setdefault(sk, []).append(txn_date)
        assert txn_date == end
        assert txn_date > MSI_AS_OF
        assert (start, end) == period_bounds(
            allows_cutoff=True, cutoff_day=6, year=end.year, month=end.month
        )
        assert abono == Decimal("0.00")
        assert amount == abono - cargo
        assert occurrence == 1
    dec, jan, feb, mar, apr = (
        date(2026, 12, 6),
        date(2027, 1, 6),
        date(2027, 2, 6),
        date(2027, 3, 6),
        date(2027, 4, 6),
    )
    assert sorted(by_plan.values(), key=len) == [[dec], [dec, jan], [dec, jan, feb, mar, apr]]
    purchase_dates = {date(2026, 10, 17), date(2026, 4, 4), date(2026, 3, 19)}
    assert not purchase_dates & {row[0] for row in rows}
    assert len({row[8] for row in rows}) == 8
    total = sum(row[4] for row in rows)
    assert total == Decimal("23902.38")
    fiesta = [row for row in rows if row[4] == Decimal("3882.50")]
    assert len(fiesta) == 5
    assert conn.execute("SELECT COUNT(*) FROM public.credit_plan_closed_f").fetchone()[0] == 0
    assert _count(conn, "master_credit_open_f", credit_id) == 0
    assert _count(conn, "master_credit_closed_f", credit_id) == 0
    account = next(item for item in _home(conn, MSI_AS_OF)["accounts"] if item["account_id"] == credit_id)
    assert account["future_row_count"] == 8
    assert Decimal(str(account["future_total"])) == Decimal("23902.38")


def test_future_replace_is_per_account_and_needs_future_rows(conn):
    user_id, tenant_id = _user(conn, "msi-replace@example.com")
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    first = _create(conn, "bank credit card", "Card A", "1111", 6, 20, as_of=MSI_AS_OF)
    second = _create(conn, "bank credit card", "Card B", "2222", 20, 20, as_of=MSI_AS_OF)
    first_slot = _current(conn, first, MSI_AS_OF)["cutoff_id"]
    second_slot = _current(conn, second, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, first, first_slot, "installment", "a.csv", _msi_text(), MSI_AS_OF)
    _ingest(conn, second, second_slot, "installment", "b.csv", _msi_text(), MSI_AS_OF)
    assert _count(conn, "master_credit_future_f", first) == 8
    assert _count(conn, "master_credit_future_f", second) == 8
    # Card B (cutoff day 20) is due on the 20th from 2026-11-20 on.
    assert conn.execute(
        "SELECT MIN(txn_date) FROM public.master_credit_future_f WHERE account_id = %s",
        (second,),
    ).fetchone()[0] == date(2026, 11, 20)

    header = _msi_text().splitlines()[0]
    one_left = f"{header}\r\n19/03/2026,0.0000%,13499.00,1499.88,AMAZON A MESES         CIUDAD DE MEX, 01/09,1499.89\r\n"
    replaced = _ingest(conn, first, first_slot, "installment", "a2.csv", one_left, MSI_AS_OF)
    assert replaced["row_count"] == 1
    assert replaced["replaced_uploads"] == 1
    assert conn.execute(
        "SELECT txn_date, cargos FROM public.master_credit_future_f WHERE account_id = %s",
        (first,),
    ).fetchall() == [(date(2026, 12, 6), Decimal("1499.88"))]
    assert _count(conn, "master_credit_future_f", second) == 8
    assert conn.execute(
        """
        SELECT COUNT(*) FROM public.statement_uploads_f
        WHERE account_id = %s AND dataset = 'credit_plan'
        """,
        (first,),
    ).fetchone()[0] == 1

    nothing_left = f"{header}\r\n19/03/2026,0.0000%,13499.00,0.00,AMAZON A MESES         CIUDAD DE MEX, 00/09,1499.89\r\n"
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'installment', 'paid.csv', %s, %s)",
        (first, first_slot, nothing_left, MSI_AS_OF),
        "no payments due after",
        "22P02",
    )
    assert _count(conn, "master_credit_future_f", first) == 1
    assert _count(conn, "master_credit_future_f", second) == 8

    # The installment slot also works on a closed period and still lands in future.
    closed_slot = _period(conn, first, "2026-11", MSI_AS_OF)["cutoff_id"]
    again = _ingest(conn, first, closed_slot, "installment", "a3.csv", _msi_text(), MSI_AS_OF)
    assert again["ledger_state"] == "future"
    assert _count(conn, "master_credit_future_f", first) == 8
    assert _count(conn, "master_credit_future_f", second) == 8


def test_open_period_routes_and_replaces_per_account(conn):
    user_id, tenant_id = _user(conn, "open-period@example.com")
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    other_id = _create(conn, "bank debit", "Savings", "0640", as_of=MSI_AS_OF)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)

    current = _current(conn, debit_id, MSI_AS_OF)
    assert (current["period_start"], current["period_end"]) == ("2026-11-01", "2026-11-30")
    assert current["show_statement_slot"] is True
    assert current["ledger_state"] == "open"
    assert current["removable"] is False
    _expect_error(
        conn,
        "SELECT public.remove_statement_period(%s, %s)",
        (current["cutoff_id"], MSI_AS_OF),
        "not in the past",
        "22023",
    )

    opened = _ingest(conn, debit_id, current["cutoff_id"], "statement", "0639.csv", OPEN_DEBIT_CSV, MSI_AS_OF)
    assert opened["ledger_state"] == "open"
    assert opened["target_table"] == "master_debit_open_f"
    other_current = _current(conn, other_id, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, other_id, other_current, "statement", "0640.csv", OPEN_DEBIT_CSV, MSI_AS_OF)
    assert _count(conn, "master_debit_open_f", debit_id) == 3
    assert _count(conn, "master_debit_closed_f", debit_id) == 0
    rows = conn.execute(
        """
        SELECT period_start, period_end, cargos, abonos, amount, occurrence, source_profile
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_debit_open_f') AS m
        WHERE account_id = %s
        ORDER BY txn_date, concept_sk
        """,
        (debit_id,),
    ).fetchall()
    assert rows[0][:2] == (date(2026, 11, 1), date(2026, 11, 30))
    assert rows[0][2:5] == (Decimal("-250.00"), Decimal("0.00"), Decimal("-250.00"))
    assert rows[0][6] == "banorte_debit_v1"
    # Same hash rule as closed, so dimensions carry over.
    expected_hash = _v2(conn, debit_id, date(2026, 11, 3), "4411", Decimal("0"), Decimal("-250"), 1)
    assert conn.execute(
        "SELECT COUNT(*) FROM public.debit_d WHERE row_hash = %s",
        (expected_hash,),
    ).fetchone()[0] == 1

    after = _current(conn, debit_id, MSI_AS_OF)
    assert after["statement_ledger_state"] == "open"
    assert after["show_statement_slot"] is True
    smaller = _ingest(
        conn, debit_id, current["cutoff_id"], "statement", "0639.csv", OPEN_DEBIT_CSV_SMALLER, MSI_AS_OF
    )
    assert smaller["replaced_uploads"] == 1
    assert _count(conn, "master_debit_open_f", debit_id) == 1
    assert _count(conn, "master_debit_open_f", other_id) == 3
    assert conn.execute(
        "SELECT COUNT(*) FROM public.statement_uploads_f WHERE account_id = %s AND ledger_state = 'open'",
        (debit_id,),
    ).fetchone()[0] == 1

    # Closed periods still land in the closed master and leave open rows alone.
    closed = _period(conn, debit_id, "2026-10", MSI_AS_OF)
    assert closed["is_current"] is False
    loaded = _ingest(conn, debit_id, closed["cutoff_id"], "statement", "oct.csv", DEBIT_CSV, MSI_AS_OF)
    assert loaded["ledger_state"] == "closed"
    assert _count(conn, "master_debit_closed_f", debit_id) == 3
    assert _count(conn, "master_debit_open_f", debit_id) == 1

    credit_current = _current(conn, credit_id, MSI_AS_OF)
    credit_open = _ingest(
        conn, credit_id, credit_current["cutoff_id"], "statement", "3978.csv", OPEN_CREDIT_CSV, MSI_AS_OF
    )
    assert credit_open["target_table"] == "master_credit_open_f"
    credit_rows = conn.execute(
        """
        SELECT period_start, period_end, abonos, cargos, amount
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_credit_open_f') AS m
        WHERE account_id = %s
        ORDER BY txn_date
        """,
        (credit_id,),
    ).fetchall()
    assert credit_rows == [
        (date(2026, 11, 7), date(2026, 12, 6), Decimal("0.00"), Decimal("85.50"), Decimal("-85.50")),
        (date(2026, 11, 7), date(2026, 12, 6), Decimal("500.00"), Decimal("0.00"), Decimal("500.00")),
    ]
    assert _count(conn, "master_credit_closed_f", credit_id) == 0

    conn.execute("SELECT public.delete_statement_upload(%s)", (credit_open["file_id"],))
    assert _count(conn, "master_credit_open_f", credit_id) == 0


def test_open_upload_becomes_closed_slot_after_cutoff(conn):
    user_id, tenant_id = _user(conn, "rollover@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=AS_OF)
    october = _current(conn, debit_id, AS_OF)
    assert october["period_label"] == "2026-10"
    _ingest(conn, debit_id, october["cutoff_id"], "statement", "0639.csv", DEBIT_CSV, AS_OF)
    assert _count(conn, "master_debit_open_f", debit_id) == 3

    stale = _period(conn, debit_id, "2026-10", MSI_AS_OF)
    assert stale["is_current"] is False
    assert stale["statement_ledger_state"] == "open"
    assert stale["show_statement_slot"] is True
    closed = _ingest(conn, debit_id, stale["cutoff_id"], "statement", "oct.csv", DEBIT_CSV, MSI_AS_OF)
    assert closed["ledger_state"] == "closed"
    assert closed["replaced_uploads"] == 1
    assert _count(conn, "master_debit_open_f", debit_id) == 0
    assert _count(conn, "master_debit_closed_f", debit_id) == 3
    assert _period(conn, debit_id, "2026-10", MSI_AS_OF)["show_statement_slot"] is False


def test_closed_path_appends_and_rejects_duplicate_hashes(conn):
    user_id, tenant_id = _user(conn, "closed-append@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639")
    september = _period(conn, debit_id, "2026-09")["cutoff_id"]
    august = _period(conn, debit_id, "2026-08")["cutoff_id"]
    _ingest(conn, debit_id, september, "statement", "sep.csv", DEBIT_CSV)
    august_csv = "Fecha,Concepto,Cargos,Abonos,Saldos\n15/08/2026,SPEI 900,-10.0,0.0,5.0\n"
    _ingest(conn, debit_id, august, "statement", "aug.csv", august_csv)
    assert _count(conn, "master_debit_closed_f", debit_id) == 4
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'sep2.csv', %s, %s)",
        (debit_id, september, august_csv, AS_OF),
        "already uploaded",
        "23505",
    )
    july = _period(conn, debit_id, "2026-07")["cutoff_id"]
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'jul.csv', %s, %s)",
        (debit_id, july, DEBIT_CSV, AS_OF),
        "already uploaded",
        "23505",
    )
    _expect_error(
        conn,
        "DELETE FROM public.master_debit_closed_f WHERE account_id = %s",
        (debit_id,),
        "only the whole uploaded file can be deleted",
        "42501",
    )
    assert _count(conn, "master_debit_closed_f", debit_id) == 4
    assert _count(conn, "master_debit_open_f", debit_id) == 0


def test_upcoming_period_is_not_open_for_upload(conn):
    user_id, tenant_id = _user(conn, "upcoming@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    current = _current(conn, debit_id, MSI_AS_OF)["cutoff_id"]
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'early.csv', %s, %s)",
        (debit_id, current, OPEN_DEBIT_CSV, date(2026, 10, 20)),
        "not open for upload yet",
        "22023",
    )


def _columns(conn, table):
    return conn.execute(
        """
        SELECT column_name, data_type, numeric_precision, numeric_scale, is_nullable, is_identity
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = %s
        ORDER BY ordinal_position
        """,
        (table,),
    ).fetchall()


def _shape(conn, table):
    constraints = conn.execute(
        """
        SELECT contype, REPLACE(conname, %s, '') AS suffix
        FROM pg_constraint
        WHERE conrelid = %s::regclass
        ORDER BY 2
        """,
        (table, f"public.{table}"),
    ).fetchall()
    indexes = conn.execute(
        "SELECT REPLACE(indexname, %s, '') FROM pg_indexes WHERE schemaname = 'public' AND tablename = %s ORDER BY 1",
        (table, table),
    ).fetchall()
    rls = conn.execute(
        "SELECT relrowsecurity FROM pg_class WHERE oid = %s::regclass",
        (f"public.{table}",),
    ).fetchone()[0]
    policies = conn.execute(
        "SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = %s",
        (table,),
    ).fetchone()[0]
    return constraints, indexes, rls, policies


def test_open_and_future_tables_mirror_closed_masters(conn):
    for new_table, closed_table in (
        ("master_debit_open_f", "master_debit_closed_f"),
        ("master_credit_open_f", "master_credit_closed_f"),
        ("master_credit_future_f", "master_credit_closed_f"),
    ):
        assert _columns(conn, new_table) == _columns(conn, closed_table)
        assert _shape(conn, new_table) == _shape(conn, closed_table)
    # sql/018: source_profile and file_name come through file_id, cutoff_id is stored.
    names = [column[0] for column in _columns(conn, "master_credit_future_f")]
    assert "source_profile" not in names and "file_name" not in names
    assert names[:14] == [
        "row_id", "file_id", "tenant_id", "user_id", "account_id", "bank_id", "cutoff_id",
        "txn_date", "concept", "abonos", "cargos", "amount", "concept_sk", "row_hash",
    ]


def test_row_level_security_hides_open_and_future_rows(conn):
    owner, owner_tenant = _user(conn, "owner-ledgers@example.com")
    other, other_tenant = _user(conn, "other-ledgers@example.com")
    _session(conn, owner, owner_tenant)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    slot = _current(conn, credit_id, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, credit_id, slot, "installment", "msi.csv", _msi_text(), MSI_AS_OF)
    _ingest(conn, credit_id, slot, "statement", "3978.csv", OPEN_CREDIT_CSV, MSI_AS_OF)
    _session(conn, other, other_tenant)
    conn.execute("SET ROLE strm_app")
    assert conn.execute("SELECT COUNT(*) FROM public.master_credit_future_f").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM public.master_credit_open_f").fetchone()[0] == 0
    conn.execute("RESET ROLE")
    _session(conn, owner, owner_tenant)
    conn.execute("SET ROLE strm_app")
    assert conn.execute("SELECT COUNT(*) FROM public.master_credit_future_f").fetchone()[0] == 8
    assert conn.execute("SELECT COUNT(*) FROM public.master_credit_open_f").fetchone()[0] == 2
    conn.execute("RESET ROLE")


# --- 012: edit a credit card's cutoff day and payment window -------------------------


def _update_cutoff(conn, account_id, cutoff_day, credit_days, as_of=MSI_AS_OF):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.update_bank_account_cutoff(%s, %s, %s, %s)",
            (account_id, cutoff_day, credit_days, as_of),
        )
        return _json(cur.fetchone()[0])


def _stored_periods(conn, account_id):
    return conn.execute(
        """
        SELECT cutoff_id, period_start, period_end, cutoff_date
        FROM public.cutoff_date_f
        WHERE account_id = %s
        ORDER BY period_end
        """,
        (account_id,),
    ).fetchall()


def _assert_contiguous(periods):
    for (_, _, end, _), (_, start, _, _) in pairwise(periods):
        assert start == end + timedelta(days=1)


def test_cutoff_update_moves_empty_periods(conn):
    user_id, tenant_id = _user(conn, "cutoff-edit@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _create(conn, "bank credit card", "BBVA", "3978", 6, 20, as_of=MSI_AS_OF)
    before = _current(conn, credit_id, MSI_AS_OF)
    assert (before["period_start"], before["period_end"]) == ("2026-11-07", "2026-12-06")

    result = _update_cutoff(conn, credit_id, 20, 25)
    assert result["account_cutoff_day"] == 20
    assert result["credit_days"] == 25
    assert result["previous_cutoff_day"] == 6
    assert result["frozen_periods"] == 0
    assert result["future_rows_redated"] == 0
    assert conn.execute(
        "SELECT account_cutoff_day, credit_days FROM public.bank_accounts_d WHERE account_id = %s",
        (credit_id,),
    ).fetchone() == (20, 25)

    # Empty current period follows the new day.
    current = _current(conn, credit_id, MSI_AS_OF)
    assert (current["period_start"], current["period_end"]) == ("2026-10-21", "2026-11-20")
    stored = _stored_periods(conn, credit_id)
    _assert_contiguous(stored)
    for _, start, end, cutoff in stored:
        assert cutoff == end
        assert (start, end) == period_bounds(allows_cutoff=True, cutoff_day=20, year=end.year, month=end.month)
    account = next(item for item in _home(conn, MSI_AS_OF)["accounts"] if item["account_id"] == credit_id)
    assert account["account_cutoff_day"] == 20
    assert account["credit_days"] == 25

    # Same day, new payment window only: periods are not touched.
    again = _update_cutoff(conn, credit_id, 20, 30)
    assert again["empty_periods_replanned"] == 0
    assert _stored_periods(conn, credit_id) == stored


def test_cutoff_update_keeps_loaded_periods(conn):
    user_id, tenant_id = _user(conn, "cutoff-loaded@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _create(conn, "bank credit card", "BBVA", "3978", 6, 20, as_of=MSI_AS_OF)
    closed = _period(conn, credit_id, "2026-10", MSI_AS_OF)
    assert (closed["period_start"], closed["period_end"]) == ("2026-09-07", "2026-10-06")
    _ingest(conn, credit_id, closed["cutoff_id"], "statement", "oct.csv", CREDIT_CSV, MSI_AS_OF)
    current = _current(conn, credit_id, MSI_AS_OF)
    _ingest(conn, credit_id, current["cutoff_id"], "statement", "nov.csv", OPEN_CREDIT_CSV, MSI_AS_OF)
    frozen = {
        row[0]: row
        for row in _stored_periods(conn, credit_id)
        if row[0] in (closed["cutoff_id"], current["cutoff_id"])
    }
    assert len(frozen) == 2

    result = _update_cutoff(conn, credit_id, 20, 20)
    assert result["frozen_periods"] == 2
    after = {row[0]: row for row in _stored_periods(conn, credit_id)}
    for cutoff_id, row in frozen.items():
        assert after[cutoff_id] == row
    _assert_contiguous(list(after.values()))

    # The loaded open period stays current and keeps its rows and bounds.
    still = _current(conn, credit_id, MSI_AS_OF)
    assert still["cutoff_id"] == current["cutoff_id"]
    assert (still["period_start"], still["period_end"]) == ("2026-11-07", "2026-12-06")
    assert still["statement_ledger_state"] == "open"
    assert _count(conn, "master_credit_open_f", credit_id) == 2
    # The empty gap between the two loaded periods is one period (Oct 7 - Nov 6).
    gap = _period(conn, credit_id, "2026-11", MSI_AS_OF)
    assert (gap["period_start"], gap["period_end"]) == ("2026-10-07", "2026-11-06")
    # The new day starts with the next period: Dec 7 - Jan 20, then Jan 21 - Feb 20.
    december = _current(conn, credit_id, date(2026, 12, 10))
    assert (december["period_start"], december["period_end"]) == ("2026-12-07", "2027-01-20")
    january = _current(conn, credit_id, date(2027, 1, 25))
    assert (january["period_start"], january["period_end"]) == ("2027-01-21", "2027-02-20")
    _assert_contiguous(_stored_periods(conn, credit_id))
    # Later refreshes never rewrite the loaded rows.
    after_later = {row[0]: row for row in _stored_periods(conn, credit_id)}
    for cutoff_id, row in frozen.items():
        assert after_later[cutoff_id] == row


def test_cutoff_update_redates_future_installments(conn):
    user_id, tenant_id = _user(conn, "cutoff-msi@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _create(conn, "bank credit card", "BBVA", "3978", 6, 20, as_of=MSI_AS_OF)
    slot = _current(conn, credit_id, MSI_AS_OF)["cutoff_id"]
    _ingest(conn, credit_id, slot, "installment", "msi.csv", _msi_text(), MSI_AS_OF)
    query = """
        SELECT txn_date, period_start, period_end, concept_sk, cargos, occurrence, row_hash, file_id
        FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_credit_future_f') AS m
        WHERE account_id = %s
        ORDER BY concept_sk, txn_date
    """
    before = conn.execute(query, (credit_id,)).fetchall()
    assert len(before) == 8

    result = _update_cutoff(conn, credit_id, 20, 20)
    assert result["future_rows_redated"] == 8
    rows = conn.execute(query, (credit_id,)).fetchall()
    assert len(rows) == 8
    assert {row[7] for row in rows} == {before[0][7]}
    assert sum(row[4] for row in rows) == sum(row[4] for row in before)
    by_plan: dict[str, list[date]] = {}
    for txn_date, start, end, sk, cargo, occurrence, row_hash, _ in rows:
        by_plan.setdefault(sk, []).append(txn_date)
        assert txn_date == end
        assert txn_date > MSI_AS_OF
        assert (start, end) == period_bounds(allows_cutoff=True, cutoff_day=20, year=end.year, month=end.month)
        assert row_hash == _v2(conn, credit_id, txn_date, sk, 0, cargo, occurrence)
        assert conn.execute(
            "SELECT COUNT(*) FROM public.credit_d WHERE row_hash = %s",
            (row_hash,),
        ).fetchone()[0] == 1
    nov, dec, jan, feb, mar = (
        date(2026, 11, 20),
        date(2026, 12, 20),
        date(2027, 1, 20),
        date(2027, 2, 20),
        date(2027, 3, 20),
    )
    assert sorted(by_plan.values(), key=len) == [[nov], [nov, dec], [nov, dec, jan, feb, mar]]
    assert len({row[6] for row in rows}) == 8


def test_cutoff_update_rejects_debit_and_bad_values(conn):
    user_id, tenant_id = _user(conn, "cutoff-bad@example.com")
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    credit_id = _create(conn, "bank credit card", "BBVA", "3978", 6, 20, as_of=MSI_AS_OF)
    sql = "SELECT public.update_bank_account_cutoff(%s, %s, %s, %s)"
    _expect_error(conn, sql, (debit_id, 6, 20, MSI_AS_OF), "Debit accounts do not have a cutoff day", "23514")
    for day in (0, 32, None):
        _expect_error(conn, sql, (credit_id, day, 20, MSI_AS_OF), "cutoff day from 1 to 31", "23514")
    for days in (0, 91, None):
        _expect_error(conn, sql, (credit_id, 20, days, MSI_AS_OF), "payment window from 1 to 90", "23514")
    assert conn.execute(
        "SELECT account_cutoff_day, credit_days FROM public.bank_accounts_d WHERE account_id = %s",
        (credit_id,),
    ).fetchone() == (6, 20)
    assert conn.execute(
        "SELECT account_cutoff_day, credit_days FROM public.bank_accounts_d WHERE account_id = %s",
        (debit_id,),
    ).fetchone() == (None, None)


def test_cutoff_update_is_scoped_to_tenant_and_user(conn):
    owner, owner_tenant = _user(conn, "cutoff-owner@example.com")
    other, other_tenant = _user(conn, "cutoff-other@example.com")
    _session(conn, owner, owner_tenant)
    credit_id = _create(conn, "bank credit card", "BBVA", "3978", 6, 20, as_of=MSI_AS_OF)
    _session(conn, other, other_tenant)
    conn.execute("SET ROLE strm_app")
    _expect_error(
        conn,
        "SELECT public.update_bank_account_cutoff(%s, %s, %s, %s)",
        (credit_id, 20, 20, MSI_AS_OF),
        "account not found",
        "P0002",
    )
    conn.execute("RESET ROLE")
    _session(conn, owner, owner_tenant)
    assert conn.execute(
        "SELECT account_cutoff_day FROM public.bank_accounts_d WHERE account_id = %s",
        (credit_id,),
    ).fetchone() == (6,)
    conn.execute("SET ROLE strm_app")
    assert _update_cutoff(conn, credit_id, 20, 20)["account_cutoff_day"] == 20
    conn.execute("RESET ROLE")


# --- 013: chosen file names and standard vault keys -----------------------------------

PDF_BYTES = b"%PDF-1.4\n% sample statement\n"
_SPEC = importlib.util.spec_from_file_location(
    "curated_key_migration", REPO_ROOT / "scripts" / "curated_key_migration.py"
)
key_migration = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(key_migration)


def _upload(conn, account_id, cutoff_id, slot, filename, chosen, csv_text, as_of=AS_OF):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.ingest_statement_upload(%s, %s, %s, %s, %s, %s, %s)",
            (account_id, cutoff_id, slot, filename, chosen, csv_text, as_of),
        )
        return _json(cur.fetchone()[0])


def _upload_pdf(conn, account_id, cutoff_id, chosen, as_of=AS_OF):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.ingest_period_pdf_upload(%s, %s, %s, %s, %s, %s)",
            (account_id, cutoff_id, chosen, chosen, base64.b64encode(PDF_BYTES).decode(), as_of),
        )
        return _json(cur.fetchone()[0])


def _upload_row(conn, upload_id):
    return conn.execute(
        """
        SELECT chosen_filename, chosen_filename_source, original_filename, curated_s3_key,
               curated_legacy_s3_key, curated_backup_s3_key, tenant_id::text
        FROM public.statement_uploads_f
        WHERE upload_id = %s
        """,
        (upload_id,),
    ).fetchone()


def _expected_key(tenant_id, bank, account, period_end, slot, version=1):
    return standard_object_key(
        tenant_id=str(tenant_id),
        bank_name=bank,
        account_number=account,
        period_end=date.fromisoformat(period_end),
        slot=slot,
        version=version,
    )


def test_chosen_name_is_stored_and_shown(conn):
    user_id, tenant_id = _user(conn, "chosen-name@example.com")
    _session(conn, user_id, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639")
    september = _period(conn, debit_id, "2026-09")
    chosen = "Movimientos Septiembre (3).XLSX"
    loaded = _upload(conn, debit_id, september["cutoff_id"], "statement", chosen, chosen, DEBIT_CSV)
    assert loaded["row_count"] == 3
    assert loaded["chosen_filename"] == chosen
    # The working CSV name keeps the pre-013 rule (spreadsheet -> Bank_Account_YYYY-MM.csv).
    assert loaded["stored_filename"] == "Banorte_0639_2026-09.csv"
    # Free plan: no vault copy, so no vault name is handed out.
    assert loaded["vault_key"] is None
    assert conn.execute(
        "SELECT COUNT(*) FROM public.curated_vault_keys_d WHERE upload_id = %s", (loaded["upload_id"],)
    ).fetchone()[0] == 0
    row = _upload_row(conn, loaded["upload_id"])
    assert row[:3] == (chosen, "chosen", "Banorte_0639_2026-09.csv")
    assert row[3] is None
    assert conn.execute(
        "SELECT DISTINCT file_name FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_debit_closed_f') AS m WHERE file_id = %s",
        (loaded["upload_id"],),
    ).fetchall() == [("Banorte_0639_2026-09.csv",)]
    shown = _period(conn, debit_id, "2026-09")
    assert shown["statement_filename"] == chosen
    assert shown["statement_stored_filename"] == "Banorte_0639_2026-09.csv"
    assert shown["statement_vault_key"] is None

    # A messy bank export name is kept as picked (trimmed, control characters dropped).
    august = _period(conn, debit_id, "2026-08")
    messy = "  Estado de cuenta Banorte 0639 \u00bfoct\u00a0(1).csv\t "
    other_csv = DEBIT_CSV.replace("07/10/2025", "08/10/2025").replace("03/10/2025", "04/10/2025")
    loaded = _upload(conn, debit_id, august["cutoff_id"], "statement", messy, messy, other_csv)
    assert loaded["chosen_filename"] == "Estado de cuenta Banorte 0639 \u00bfoct\u00a0(1).csv"
    assert _period(conn, debit_id, "2026-08")["statement_filename"] == loaded["chosen_filename"]

    # Old entry point without a chosen name: the working name is reused and marked legacy.
    july = _period(conn, debit_id, "2026-07")
    third_csv = DEBIT_CSV.replace("07/10/2025", "09/10/2025").replace("03/10/2025", "05/10/2025")
    legacy = _ingest(conn, debit_id, july["cutoff_id"], "statement", "export.csv", third_csv)
    assert _upload_row(conn, legacy["upload_id"])[:2] == ("Banorte_0639_2026-07.csv", "legacy")


def test_vault_names_versions_metadata_and_manifest(conn):
    user_id, tenant_id = _user(conn, "vault-keys@example.com")
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    current = _current(conn, credit_id, MSI_AS_OF)
    october = _period(conn, credit_id, "2026-10", MSI_AS_OF)
    folder = f"curated/{tenant_id}"
    # Current period Nov 7 - Dec 6 2026: its period (period_end) is 2026-12.
    plan = _upload(
        conn, credit_id, current["cutoff_id"], "installment", "msi.csv", "Meses sin intereses.csv", _msi_text(), MSI_AS_OF
    )
    assert plan["vault_key"] == f"{folder}/2026-12_3978_Banorte_msi.csv"
    statement = _upload(
        conn, credit_id, current["cutoff_id"], "statement", "3978.csv", "A\u00f1o 3978 nov.csv", OPEN_CREDIT_CSV, MSI_AS_OF
    )
    assert statement["vault_key"] == f"{folder}/2026-12_3978_Banorte.csv"
    pdf = _upload_pdf(conn, credit_id, october["cutoff_id"], "Estado de cuenta Oct.pdf", MSI_AS_OF)
    assert pdf["vault_key"] == f"{folder}/2026-10_3978_Banorte.pdf"
    assert pdf["vault_key"] == _expected_key(tenant_id, "Banorte", "3978", october["period_end"], "pdf")
    assert _period(conn, credit_id, "2026-10", MSI_AS_OF)["pdf_filename"] == "Estado de cuenta Oct.pdf"

    # Metadata: ASCII, percent-encoded UTF-8, same as the Python helper.
    metadata = statement["vault_metadata"]
    assert metadata["original-filename"] == "A%C3%B1o%203978%20nov.csv" == metadata_value("A\u00f1o 3978 nov.csv")
    assert metadata["value-encoding"] == "percent-utf8"
    assert (metadata["bank"], metadata["account"], metadata["period"]) == ("Banorte", "3978", "2026-12")
    assert (metadata["period-start"], metadata["period-end"]) == ("2026-11-07", "2026-12-06")
    assert metadata["dataset"] == "credit_monthly"
    assert metadata["upload-id"] == str(statement["upload_id"])
    assert all(value.isascii() for value in metadata.values())

    # Manifest: enough to rebuild the account, period and upload rows.
    assert statement["vault_manifest_key"] == f"{folder}/manifest/2026-12_3978_Banorte.csv.json"
    assert statement["vault_manifest_key"] == manifest_key(statement["vault_key"])
    manifest = statement["vault_manifest"]
    assert manifest["schema"] == "bankstream-vault-manifest/1"
    assert manifest["vault_key"] == statement["vault_key"]
    assert manifest["chosen_filename"] == "A\u00f1o 3978 nov.csv"
    assert manifest["upload_id"] == str(statement["upload_id"])
    assert manifest["ledger_state"] == "open"
    assert manifest["slot"] == "statement"
    assert manifest["bank_name"] == "Banorte"
    assert manifest["account"]["account_number"] == "3978"
    assert manifest["account"]["account_type"].lower() == "bank credit card"
    assert (manifest["account"]["cutoff_day"], manifest["account"]["credit_days"]) == (6, 20)
    assert manifest["period"] == {
        "period": "2026-12",
        "period_start": "2026-11-07",
        "period_end": "2026-12-06",
        "cutoff_date": "2026-12-06",
    }
    assert len(manifest["content_sha256"]) == 64

    # Open-period replace: same name, next version (write-once never overwrites).
    again = _upload(
        conn, credit_id, current["cutoff_id"], "statement", "3978.csv", "3978 nov v2.csv", OPEN_CREDIT_CSV, MSI_AS_OF
    )
    assert again["vault_key"] == f"{folder}/2026-12_3978_Banorte_v2.csv"
    assert again["vault_key"] == _expected_key(tenant_id, "Banorte", "3978", current["period_end"], "statement", 2)
    # Delete and upload again: the deleted file's name stays used, so v3.
    conn.execute("SELECT public.attach_curated_backup(%s, %s)", (again["upload_id"], again["vault_key"]))
    marker = _json(
        conn.execute("SELECT public.vault_delete_marker(%s)", (again["upload_id"],)).fetchone()[0]
    )
    assert marker["key"] == f"{folder}/manifest/2026-12_3978_Banorte_v2.csv.deleted.json"
    assert marker["body"]["vault_key"] == again["vault_key"]
    conn.execute("SELECT public.delete_statement_upload(%s)", (again["upload_id"],))
    third = _upload(
        conn, credit_id, current["cutoff_id"], "statement", "3978.csv", "3978 nov v3.csv", OPEN_CREDIT_CSV, MSI_AS_OF
    )
    assert third["vault_key"] == f"{folder}/2026-12_3978_Banorte_v3.csv"
    # No vault object yet: no delete marker.
    assert conn.execute("SELECT public.vault_delete_marker(%s)", (third["upload_id"],)).fetchone()[0] is None

    # attach_curated_backup takes the vault name or the legacy key of that upload only.
    conn.execute("SELECT public.attach_curated_backup(%s, %s)", (pdf["upload_id"], pdf["vault_key"]))
    assert _upload_row(conn, pdf["upload_id"])[3] == pdf["vault_key"]
    conn.execute(
        "SELECT public.attach_curated_backup(%s, %s)",
        (plan["upload_id"], legacy_object_key(str(tenant_id), str(plan["upload_id"]), "csv")),
    )
    for wrong in (f"{folder}/anything.csv", statement["vault_key"]):
        _expect_error(
            conn,
            "SELECT public.attach_curated_backup(%s, %s)",
            (third["upload_id"], wrong),
            "does not match the vault name",
            "22023",
        )
    assert _period(conn, credit_id, "2026-10", MSI_AS_OF)["pdf_vault_key"] == pdf["vault_key"]

    # The app role cannot read or write the registry directly.
    conn.execute("SET ROLE strm_app")
    _expect_error(conn, "SELECT COUNT(*) FROM public.curated_vault_keys_d", (), "permission denied")
    conn.execute("RESET ROLE")


def test_standard_key_sql_matches_python(conn):
    tenant = "4b1f0c3e-1111-4222-8333-944455556666"
    cases = [
        ("Banorte", "0639", date(2026, 9, 30), "statement", 1),
        ("BBVA M\u00e9xico", "3978", date(2026, 12, 6), "installment", 1),
        ("  HSBC / Premier..", "12 34", date(2027, 1, 20), "pdf", 3),
        ("__a__b__", "", date(2026, 2, 28), "statement", 2),
    ]
    for bank, account, period_end, slot, version in cases:
        sql_key = conn.execute(
            "SELECT public.curated_standard_key(%s, %s, %s, %s, %s, %s)",
            (tenant, bank, account, period_end, slot, version),
        ).fetchone()[0]
        assert sql_key == standard_object_key(
            tenant_id=tenant, bank_name=bank, account_number=account,
            period_end=period_end, slot=slot, version=version,
        )
        assert re.fullmatch(r"curated/[0-9a-f-]{36}/\d{4}-\d{2}_[A-Za-z0-9_.\-]+\.(csv|pdf)", sql_key)
    assert standard_object_key(
        tenant_id=tenant, bank_name="BBVA M\u00e9xico", account_number="3978",
        period_end=date(2026, 12, 6), slot="installment",
    ) == f"curated/{tenant}/2026-12_3978_BBVA_M_xico_msi.csv"
    assert standard_object_key(
        tenant_id=tenant, bank_name="HSBC", account_number="4598",
        period_end=date(2026, 10, 31), slot="pdf", version=2,
    ) == f"curated/{tenant}/2026-10_4598_HSBC_v2.pdf"
    for value in ("Octubre.pdf", "0639 08 Consulta_23102026 (1).csv", "A\u00f1o ~ \u00e9 #%&?.csv", "x" * 300, ""):
        sql_value = conn.execute("SELECT public.curated_meta_value(%s)", (value,)).fetchone()[0]
        assert sql_value == metadata_value(value)
        assert sql_value.isascii()
    _expect_error(
        conn,
        "SELECT public.curated_standard_key(%s, 'Banorte', '1', '2026-01-31', 'other', 1)",
        (tenant,),
        "slot must be statement, installment or pdf",
        "22023",
    )
    _expect_error(
        conn,
        "SELECT public.curated_standard_key(%s, 'Banorte', '1', '2026-01-31', 'pdf', 0)",
        (tenant,),
        "vault version must be 1 or more",
        "22023",
    )


class _FakeS3:
    def __init__(self, objects):
        self.objects = {key: (body, {}) for key, body in objects.items()}
        self.copies = []
        self.puts = []

    def head_object(self, Bucket, Key):
        if Key not in self.objects:
            error = Exception("not found")
            error.response = {"Error": {"Code": "404"}}
            raise error
        body, metadata = self.objects[Key]
        return {"ContentLength": len(body), "ETag": f'"{hash(body)}"', "ContentType": "text/csv", "Metadata": metadata}

    def copy_object(self, **params):
        self.copies.append(params)
        body, metadata = self.objects[params["CopySource"]["Key"]]
        if params["MetadataDirective"] == "REPLACE":
            metadata = params["Metadata"]
        self.objects[params["Key"]] = (body, metadata)
        return {}

    def put_object(self, **params):
        assert params["IfNoneMatch"] == "*"
        self.puts.append(params)
        self.objects[params["Key"]] = (params["Body"], params.get("Metadata", {}))
        return {}


def test_existing_vault_objects_dry_run_and_copy(conn):
    user_id, tenant_id = _user(conn, "vault-migrate@example.com")
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    debit_id = _create(conn, "bank debit", "Payroll", "0639")
    folder = f"curated/{tenant_id}"
    september = _period(conn, debit_id, "2026-09")
    # Pre-013 path: no vault name reserved, object under its upload id.
    loaded = _ingest(conn, debit_id, september["cutoff_id"], "statement", "0639 09 Consulta (1).csv", DEBIT_CSV)
    old_key = legacy_object_key(str(tenant_id), str(loaded["upload_id"]), "csv")
    conn.execute("SELECT public.attach_curated_backup(%s, %s)", (loaded["upload_id"], old_key))
    # 2026-08: a file was uploaded with 013 and deleted (its name stays used), then a
    # legacy upload took the slot, so the migration must give it _v2.
    august = _period(conn, debit_id, "2026-08")
    aug_csv = DEBIT_CSV.replace("07/10/2025", "08/10/2025").replace("03/10/2025", "04/10/2025")
    first = _upload(conn, debit_id, august["cutoff_id"], "statement", "aug.csv", "aug.csv", aug_csv)
    assert first["vault_key"] == f"{folder}/2026-08_0639_Banorte.csv"
    conn.execute("SELECT public.delete_statement_upload(%s)", (first["upload_id"],))
    second = _ingest(conn, debit_id, august["cutoff_id"], "statement", "aug again.csv", aug_csv)
    second_old = legacy_object_key(str(tenant_id), str(second["upload_id"]), "csv")
    conn.execute("SELECT public.attach_curated_backup(%s, %s)", (second["upload_id"], second_old))
    # A database-only upload (no vault key) is skipped.
    july = _period(conn, debit_id, "2026-07")
    jul_csv = DEBIT_CSV.replace("07/10/2025", "09/10/2025").replace("03/10/2025", "05/10/2025")
    _ingest(conn, debit_id, july["cutoff_id"], "statement", "jul.csv", jul_csv)

    plan = [item for item in key_migration.load_plan(conn, "20261112") if item["tenant_id"] == str(tenant_id)]
    # Same transaction, same created_at: order by name for a stable test.
    plan.sort(key=lambda item: item["new_key"], reverse=True)
    assert [(item["current_key"], item["new_key"], item["action"]) for item in plan] == [
        (old_key, f"{folder}/2026-09_0639_Banorte.csv", "copy"),
        (second_old, f"{folder}/2026-08_0639_Banorte_v2.csv", "copy"),
    ]
    assert plan[0] == {
        "upload_id": str(loaded["upload_id"]),
        "tenant_id": str(tenant_id),
        "dataset": "debit",
        "chosen_filename": "0639 09 Consulta (1).csv",
        "current_key": old_key,
        "backup_key": f"curated/backup-20261112/{tenant_id}/{loaded['upload_id']}.csv",
        "new_key": f"{folder}/2026-09_0639_Banorte.csv",
        "manifest_key": f"{folder}/manifest/2026-09_0639_Banorte.csv.json",
        "action": "copy",
    }
    assert plan[0]["backup_key"] == backup_object_key(old_key, "20261112")
    text = key_migration.format_plan(plan)
    assert text.splitlines()[0] == ",".join(key_migration.PLAN_COLUMNS)
    assert f"{old_key},curated/backup-20261112/" in text and text.rstrip().endswith(",copy")
    # Dry run wrote nothing and reserved nothing.
    assert _upload_row(conn, loaded["upload_id"])[3] == old_key
    assert conn.execute(
        "SELECT COUNT(*) FROM public.curated_vault_keys_d WHERE upload_id = %s", (loaded["upload_id"],)
    ).fetchone()[0] == 0

    s3 = _FakeS3({old_key: b"date,concept\n", second_old: b"date,concept,aug\n"})
    conn.commit = lambda: None  # keep the test transaction; the script commits per row
    moment = datetime(2026, 11, 12, tzinfo=timezone.utc)
    results = key_migration.apply_plan(conn, s3, "curated-bucket", plan, now=moment)
    assert [item["result"] for item in results] == [
        "backup copied, standard copied, manifest written, key updated",
    ] * 2
    assert [copy["Key"] for copy in s3.copies] == [
        plan[0]["backup_key"], plan[0]["new_key"], plan[1]["backup_key"], plan[1]["new_key"],
    ]
    backup_copy, new_copy = s3.copies[0], s3.copies[1]
    assert backup_copy["MetadataDirective"] == "COPY"
    assert new_copy["MetadataDirective"] == "REPLACE"
    assert new_copy["Metadata"]["original-filename"] == "0639%2009%20Consulta%20%281%29.csv"
    assert new_copy["Metadata"]["period"] == "2026-09"
    assert new_copy["Metadata"]["upload-id"] == str(loaded["upload_id"])
    for params in s3.copies + s3.puts:
        assert params["ObjectLockMode"] == "GOVERNANCE"
        assert params["ObjectLockRetainUntilDate"] == datetime(2027, 11, 12, tzinfo=timezone.utc)
    assert [put["Key"] for put in s3.puts] == [plan[0]["manifest_key"], plan[1]["manifest_key"]]
    written = json.loads(s3.puts[0]["Body"])
    assert written["vault_key"] == plan[0]["new_key"]
    assert written["legacy_key"] == old_key
    assert written["backup_key"] == plan[0]["backup_key"]
    assert written["period"]["period_start"] == "2026-09-01"
    assert written["account"]["account_number"] == "0639"
    assert old_key in s3.objects and second_old in s3.objects
    row = _upload_row(conn, loaded["upload_id"])
    assert row[3:6] == (plan[0]["new_key"], old_key, plan[0]["backup_key"])
    again = [item for item in key_migration.load_plan(conn, "20261112") if item["tenant_id"] == str(tenant_id)]
    assert [item["action"] for item in again] == ["already_standard", "already_standard"]
    assert again[0]["backup_key"] is None
    # Re-running is a no-op for migrated rows and never copies again.
    assert key_migration.apply_plan(conn, s3, "curated-bucket", again)[0]["result"] == "already_standard"
    assert len(s3.copies) == 4

    _expect_error(
        conn,
        "SELECT public.apply_curated_key_migration(%s, %s, %s, %s)",
        (loaded["upload_id"], plan[0]["new_key"], plan[0]["backup_key"], f"{folder}/x.csv"),
        "does not match the vault name",
        "22023",
    )
    # The app role cannot read the cross-tenant plan or rewrite keys.
    conn.execute("SET ROLE strm_app")
    _expect_error(conn, "SELECT * FROM public.curated_key_migration_plan('x')", (), "permission denied")
    conn.execute("RESET ROLE")


def test_013_backfills_chosen_name_on_existing_rows(database_url):
    admin = _admin()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin.execute(f'CREATE DATABASE "{name}"')
    url = f"postgresql:///{name}?sslmode=disable"
    try:
        apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
        before = LATER_MIGRATIONS[: LATER_MIGRATIONS.index("013_chosen_names_vault_keys.sql")]
        _apply_files(url, before, users_schema="cognito_users", database="neondb", app_schema="public")
        with psycopg.connect(url) as conn:
            user_id, tenant_id = _user(conn, "backfill@example.com")
            _session(conn, user_id, tenant_id)
            debit_id = _create(conn, "bank debit", "Payroll", "0639")
            september = _period(conn, debit_id, "2026-09")
            loaded = _ingest(conn, debit_id, september["cutoff_id"], "statement", "sept.xlsx", DEBIT_CSV)
            conn.commit()
        for _ in range(2):
            _apply_files(
                url, ("013_chosen_names_vault_keys.sql",),
                users_schema="cognito_users", database="neondb", app_schema="public",
            )
        with psycopg.connect(url) as conn:
            assert conn.execute(
                """
                SELECT chosen_filename, chosen_filename_source, original_filename
                FROM public.statement_uploads_f WHERE upload_id = %s
                """,
                (loaded["upload_id"],),
            ).fetchone() == ("Banorte_0639_2026-09.csv", "legacy", "Banorte_0639_2026-09.csv")
            assert conn.execute(
                "SELECT COUNT(*) FROM public.master_debit_closed_f WHERE file_id = %s",
                (loaded["upload_id"],),
            ).fetchone()[0] == 3
    finally:
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.close()


# --- BBVA installments: one value per line, "Pagos N de M" = N already paid ---------
BBVA_MSI_FIXTURE = FIXTURES / "bbva_msi_one_column.csv"
BBVA_MSI_XLSX = FIXTURES / "bbva_msi_one_column.xlsx"
BBVA_AS_OF = date(2026, 11, 12)
BBVA_FUTURE_QUERY = """
    SELECT txn_date, period_start, period_end, concept, cargos, abonos, amount, occurrence, row_hash,
           bank_name, account_number, source_profile
    FROM (SELECT * FROM public.movement_keys_v WHERE source_table = 'master_credit_future_f') AS m
    WHERE account_id = %s
    ORDER BY txn_date
"""


def _bbva_credit(conn, number, cutoff=3, as_of=BBVA_AS_OF):
    bank_id = conn.execute("SELECT bank_id FROM public.banks_d WHERE bank_name = 'BBVA'").fetchone()[0]
    with conn.cursor() as cur:
        cur.execute(
            "SELECT public.create_bank_account(%s, %s, %s, %s, %s, %s, %s)",
            (bank_id, _type_id(conn, "bank credit card"), "BBVA credit", number, cutoff, 20, as_of),
        )
        return cur.fetchone()[0]


def _bbva_msi_text():
    raw = BBVA_MSI_FIXTURE.read_bytes()
    assert raw.startswith(b"\xef\xbb\xbf")
    assert b"\r\n" in raw
    return decode_bank_csv(raw)


def _assert_bbva_rows(conn, account_id, number):
    rows = conn.execute(BBVA_FUTURE_QUERY, (account_id,)).fetchall()
    assert [row[0] for row in rows] == [date(2026, 11, 6), date(2026, 12, 6)]
    assert [(row[1], row[2]) for row in rows] == [
        (date(2026, 11, 4), date(2026, 12, 3)),
        (date(2026, 12, 4), date(2027, 1, 3)),
    ]
    for txn_date, _, _, concept, cargo, abono, amount, occurrence, row_hash, bank, account, profile in rows:
        assert concept == "ABONO POR TRASP. A PROMOC."
        assert cargo == Decimal("5750.00")
        assert abono == Decimal("0.00")
        assert amount == -cargo
        assert occurrence == 1
        assert (bank, account, profile) == ("BBVA", number, "bbva_credit_plan_v1")
        assert row_hash == _v2(conn, account_id, txn_date, concept_sk(concept), abono, cargo, occurrence)
    assert sum(row[4] for row in rows) == Decimal("11500.00")
    account = next(item for item in _home(conn, BBVA_AS_OF)["accounts"] if item["account_id"] == account_id)
    assert account["future_row_count"] == 2
    assert Decimal(str(account["future_total"])) == Decimal("11500.00")
    return rows


def test_bbva_text_helpers(conn):
    assert conn.execute("SELECT public.spanish_short_date('06 jul. 2026')").fetchone()[0] == date(2026, 7, 6)
    assert conn.execute("SELECT public.spanish_short_date('6 Sept 2026')").fetchone()[0] == date(2026, 9, 6)
    assert conn.execute("SELECT public.spanish_short_date('31 feb. 2026')").fetchone()[0] is None
    assert conn.execute("SELECT public.spanish_short_date('06/07/2026')").fetchone()[0] is None
    assert conn.execute("SELECT public.undouble_amount('$5,750.00$5,750.00')").fetchone()[0] == "$5,750.00"
    assert conn.execute("SELECT public.undouble_amount('5,750.00')").fetchone()[0] == "5,750.00"
    assert conn.execute("SELECT public.undouble_amount('11')").fetchone()[0] == "1"
    assert conn.execute("SELECT * FROM public.installment_paid_counts('4 de 6')").fetchone() == (4, 6)
    assert conn.execute("SELECT * FROM public.installment_paid_counts('4/6')").fetchone() == (4, 6)
    assert conn.execute("SELECT * FROM public.installment_paid_counts('pending')").fetchone() == (None, None)
    reshaped = conn.execute(
        "SELECT public.reshape_one_column_installments(%s)", (_bbva_msi_text(),)
    ).fetchone()[0]
    assert reshaped.splitlines() == [
        "Fecha,Descripcion,Compra,Mensualidad,Pagos,Interes,Saldo actual",
        '"06 jul. 2026","ABONO POR TRASP. A PROMOC.","$34,500.00","$5,750.00","4 de 6","0.00%","$11,500.00"',
    ]
    assert conn.execute(
        "SELECT public.reshape_one_column_installments(%s)", (_msi_text(),)
    ).fetchone()[0] is None


def test_bbva_one_column_msi_csv_loads_pending_payments(conn):
    user_id, tenant_id = _user(conn, "bbva-msi@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _bbva_credit(conn, "1512")
    current = _current(conn, credit_id, BBVA_AS_OF)
    assert (current["period_start"], current["period_end"]) == ("2026-11-04", "2026-12-03")
    # Generic name: bank, account and period come from the slot, not the file.
    loaded = _ingest(conn, credit_id, current["cutoff_id"], "installment", "Book1.csv", _bbva_msi_text(), BBVA_AS_OF)
    assert loaded["profile"] == "bbva_credit_plan_v1"
    assert loaded["source_row_count"] == 1
    assert loaded["row_count"] == 2
    assert loaded["target_table"] == "master_credit_future_f"
    assert (loaded["bank_name"], loaded["account_number"]) == ("BBVA", "1512")
    assert loaded["original_filename"] == "BBVA_1512_2026-12.csv"
    rows = _assert_bbva_rows(conn, credit_id, "1512")
    # 2026-11-06 is on or before the as-of date but BBVA still lists it as pending: kept.
    assert rows[0][0] <= BBVA_AS_OF
    assert _count(conn, "master_credit_open_f", credit_id) == 0
    assert conn.execute("SELECT COUNT(*) FROM public.credit_plan_closed_f").fetchone()[0] == 0


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_bbva_one_column_msi_xlsx_matches_csv(conn):
    js = REPO_ROOT / "web" / "xlsx_to_csv.js"
    script = (
        "const fs=require('fs');"
        f"eval(fs.readFileSync({str(js)!r},'utf8'));"
        f"const b=fs.readFileSync({str(BBVA_MSI_XLSX)!r});"
        "strmXlsxToCsv(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength))"
        ".then((c)=>process.stdout.write(c)).catch((e)=>{console.error(e);process.exit(1);});"
    )
    result = subprocess.run([shutil.which("node"), "-e", script], check=False, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    text = result.stdout
    assert text.splitlines()[:7] == ["Fecha", "Descripción", "Compra", "Mensualidad", "Pagos", "Interés", "Saldo actual"]
    assert text.splitlines()[12] == "0"
    user_id, tenant_id = _user(conn, "bbva-msi-xlsx@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _bbva_credit(conn, "1512")
    slot = _current(conn, credit_id, BBVA_AS_OF)["cutoff_id"]
    loaded = _ingest(conn, credit_id, slot, "installment", "Book1.xlsx", text, BBVA_AS_OF)
    assert loaded["row_count"] == 2
    _assert_bbva_rows(conn, credit_id, "1512")


def test_bbva_msi_validates_counts_and_bank(conn):
    user_id, tenant_id = _user(conn, "bbva-msi-bad@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _bbva_credit(conn, "1512")
    slot = _current(conn, credit_id, BBVA_AS_OF)["cutoff_id"]
    sql = "SELECT public.ingest_statement_csv(%s, %s, 'installment', 'Book1.csv', %s, %s)"
    text = _bbva_msi_text()
    wrong_saldo = text.replace('"$11,500.00$11,500.00"', '"$17,250.00$17,250.00"', 1)
    _expect_error(conn, sql, (credit_id, slot, wrong_saldo, BBVA_AS_OF), "does not match 2 pending payments", "22P02")
    _expect_error(conn, sql, (credit_id, slot, text.replace("4 de 6", "7 de 6"), BBVA_AS_OF), "unreadable pagos", "22P02")
    paid_off = text.replace("4 de 6", "6 de 6").replace('"$11,500.00$11,500.00"', '"$0.00$0.00"', 1)
    _expect_error(conn, sql, (credit_id, slot, paid_off, BBVA_AS_OF), "has no movements", "22P02")
    cut = "\r\n".join(text.split("\r\n")[:12])
    _expect_error(conn, sql, (credit_id, slot, cut, BBVA_AS_OF), "ends in the middle of a plan", "22P02")
    assert _count(conn, "master_credit_future_f", credit_id) == 0

    # The bank comes from the account: a Banorte card does not read the BBVA layout.
    other_user, other_tenant = _user(conn, "banorte-msi-bbva-file@example.com")
    _session(conn, other_user, other_tenant)
    banorte_id = _create(conn, "bank credit card", "Banorte credit", "3978", 6, 20, as_of=BBVA_AS_OF)
    banorte_slot = _current(conn, banorte_id, BBVA_AS_OF)["cutoff_id"]
    _expect_error(conn, sql, (banorte_id, banorte_slot, text, BBVA_AS_OF), "headers")
    assert _count(conn, "master_credit_future_f", banorte_id) == 0


def test_cutoff_update_keeps_bbva_purchase_day_dates(conn):
    user_id, tenant_id = _user(conn, "bbva-msi-cutoff@example.com")
    _session(conn, user_id, tenant_id)
    credit_id = _bbva_credit(conn, "1512")
    slot = _current(conn, credit_id, BBVA_AS_OF)["cutoff_id"]
    _ingest(conn, credit_id, slot, "installment", "Book1.csv", _bbva_msi_text(), BBVA_AS_OF)
    before = conn.execute(BBVA_FUTURE_QUERY, (credit_id,)).fetchall()
    result = _update_cutoff(conn, credit_id, 20, 20, as_of=BBVA_AS_OF)
    assert result["future_rows_redated"] == 0
    rows = conn.execute(BBVA_FUTURE_QUERY, (credit_id,)).fetchall()
    assert [row[0] for row in rows] == [date(2026, 11, 6), date(2026, 12, 6)]
    assert [row[8] for row in rows] == [row[8] for row in before]
    assert [(row[1], row[2]) for row in rows] == [
        (date(2026, 10, 21), date(2026, 11, 20)),
        (date(2026, 11, 21), date(2026, 12, 20)),
    ]


def _node_browser_prep(xlsx_path, chosen, bank, account, period):
    """What web/statements.js does before POST /uploads: XLSX -> CSV text + stored name."""
    js = REPO_ROOT / "web" / "xlsx_to_csv.js"
    script = (
        "const fs=require('fs');"
        f"eval(fs.readFileSync({str(js)!r},'utf8'));"
        f"const b=fs.readFileSync({str(xlsx_path)!r});"
        "strmXlsxToCsv(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)).then((csv)=>"
        "process.stdout.write(JSON.stringify({csv, filename: strmStoredUploadFilename("
        f"{chosen!r}, {{bank: {bank!r}, accountNumber: {account!r}, period: {period!r}}})}})))"
        ".catch((e)=>{console.error(e);process.exit(1);});"
    )
    result = subprocess.run([shutil.which("node"), "-e", script], check=False, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_installment_slot_takes_bbva_xlsx_and_banorte_csv(conn):
    web = (REPO_ROOT / "web" / "statements.js").read_text(encoding="utf-8")
    assert 'dropZone(account, period, "installment", label, sheetAccept)' in web
    assert 'const sheetAccept = ".csv,.xlsx,' in web

    # BBVA: the XLSX export is the main path. Name, bank and account come from the slot.
    user_id, tenant_id = _user(conn, "bbva-msi-upload@example.com")
    _session(conn, user_id, tenant_id)
    bbva_id = _bbva_credit(conn, "1512")
    current = _current(conn, bbva_id, BBVA_AS_OF)
    prep = _node_browser_prep(BBVA_MSI_XLSX, "Book1.xlsx", "BBVA", "1512", current["period_label"])
    assert prep["filename"].endswith(".csv") and "BBVA" in prep["filename"]
    loaded = _upload(conn, bbva_id, current["cutoff_id"], "installment", prep["filename"], "Book1.xlsx",
                     prep["csv"], BBVA_AS_OF)
    assert (loaded["row_count"], loaded["profile"]) == (2, "bbva_credit_plan_v1")
    chosen, _, stored, *_ = _upload_row(conn, loaded["upload_id"])
    assert chosen == "Book1.xlsx"
    assert stored == "BBVA_1512_2026-12.csv"
    _assert_bbva_rows(conn, bbva_id, "1512")

    # Banorte: the CSV path is unchanged.
    other_user, other_tenant = _user(conn, "banorte-msi-upload@example.com")
    _session(conn, other_user, other_tenant)
    banorte_id = _create(conn, "bank credit card", "Credit", "3978", 6, 20, as_of=MSI_AS_OF)
    slot = _current(conn, banorte_id, MSI_AS_OF)["cutoff_id"]
    loaded = _upload(conn, banorte_id, slot, "installment", "msi.csv", "msi.csv", _msi_text(), MSI_AS_OF)
    assert (loaded["row_count"], loaded["profile"]) == (8, "banorte_credit_plan_v1")
    total = conn.execute(
        "SELECT SUM(amount) FROM public.master_credit_future_f WHERE account_id = %s", (banorte_id,)
    ).fetchone()[0]
    assert total == Decimal("-23902.38")


# --- 014: normalized row_hash, abonos/cargos everywhere, bank_id, sign rule -----------
MASTERS_014 = (
    ("master_debit_closed_f", "closed", "debit"),
    ("master_debit_open_f", "open", "debit"),
    ("master_credit_closed_f", "closed", "credit"),
    ("master_credit_open_f", "open", "credit"),
    ("master_credit_future_f", "future", "credit"),
)


def test_row_hash_v2_sql_matches_python(conn):
    user = "8f14e45f-ceea-467a-9f2b-0123456789ab"
    cases = [
        (user, 7, 1, date(2026, 11, 3), "4411", Decimal("0"), Decimal("-250"), 1),
        (user, 7, 1, date(2026, 11, 3), "4411", Decimal("-0.00"), Decimal("-250.00"), 2),
        (user, 12, 3, date(2026, 12, 6), "ABONOPORTRASPAPROMOC", Decimal("0.00"), Decimal("5750"), 1),
        (user, 12, 3, date(2026, 1, 9), "PAGO", Decimal("1234567.895"), Decimal("0"), 1),
        (user, 12, 3, date(2026, 1, 9), "PAGO", Decimal("0.005"), Decimal("-0.005"), 1),
    ]
    for case in cases:
        expected = movement_row_hash_v2(*case)
        got = conn.execute(
            "SELECT public.movement_row_hash_v2(%s::uuid, %s, %s, %s, %s, %s, %s, %s)", case
        ).fetchone()[0]
        assert got == expected, case
    # Documented example (docs/row_hash.md).
    payload = f"{user}|7|1|2026-11-03|4411|0.00|-250.00|1"
    assert movement_row_hash_v2(*cases[0]) == hashlib.sha256(payload.encode()).hexdigest()
    assert conn.execute("SELECT public.movement_amount_text(-0.004)").fetchone()[0] == "0.00"
    assert conn.execute("SELECT public.movement_amount_text(-1500)").fetchone()[0] == "-1500.00"
    # Every input changes the key; occurrence separates identical same-day rows.
    base = movement_row_hash_v2(*cases[0])
    for index, other in ((1, 8), (2, 2), (4, "4412"), (5, Decimal("1")), (6, Decimal("-251")), (7, 2)):
        changed = list(cases[0])
        changed[index] = other
        assert movement_row_hash_v2(*changed) != base


def _master_snapshot(conn, before_014=False):
    out = {}
    for table, _, _ in MASTERS_014:
        source = "master_debit_future_f" if before_014 and table == "master_credit_future_f" else table
        out[table] = conn.execute(
            f"SELECT row_id, row_hash FROM public.{source} ORDER BY row_id"
        ).fetchall()
    return out


def test_014_rehashes_existing_rows_and_remaps_dimensions(database_url):
    admin = _admin()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin.execute(f'CREATE DATABASE "{name}"')
    url = f"postgresql:///{name}?sslmode=disable"
    kw = {"users_schema": "cognito_users", "database": "neondb", "app_schema": "public"}
    try:
        apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
        before_014 = LATER_MIGRATIONS[: LATER_MIGRATIONS.index("014_normalized_row_hash.sql")]
        _apply_files(url, before_014, **kw)
        with psycopg.connect(url) as conn:
            user_id, tenant_id = _user(conn, "rehash@example.com")
            _session(conn, user_id, tenant_id)
            _premium(conn, tenant_id)
            debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
            credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
            _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
                    "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
            _ingest(conn, debit_id, _current(conn, debit_id, MSI_AS_OF)["cutoff_id"],
                    "statement", "0639.csv", OPEN_DEBIT_CSV, MSI_AS_OF)
            # Two identical same-day charges: occurrence 1 and 2.
            _ingest(conn, credit_id, _period(conn, credit_id, "2026-11", MSI_AS_OF)["cutoff_id"],
                    "statement", "3978.csv", CREDIT_CSV, MSI_AS_OF)
            credit_slot = _current(conn, credit_id, MSI_AS_OF)["cutoff_id"]
            _ingest(conn, credit_id, credit_slot, "statement", "3978.csv", OPEN_CREDIT_CSV, MSI_AS_OF)
            _ingest(conn, credit_id, credit_slot, "installment", "msi.csv", _msi_text(), MSI_AS_OF)
            old = _master_snapshot(conn, before_014=True)
            old_dims = conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0]
            conn.commit()
        assert [len(old[table]) for table, _, _ in MASTERS_014] == [3, 3, 2, 2, 8]
        assert old_dims == 18

        _apply_files(url, ("014_normalized_row_hash.sql",), **kw)
        with psycopg.connect(url) as conn:
            first = _master_snapshot(conn)
            for table, _, kind in MASTERS_014:
                columns = {row[0] for row in conn.execute(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema = 'public' AND table_name = %s", (table,)
                ).fetchall()}
                assert {"abonos", "cargos", "bank_id", "user_id", "account_id"} <= columns
                assert not {"abono", "cargo"} & columns
                rows = conn.execute(
                    f"""
                    SELECT movement.row_id, movement.row_hash, movement.user_id::text, movement.account_id,
                           movement.bank_id, account.bank_id, movement.txn_date, movement.concept_sk,
                           movement.abonos, movement.cargos, movement.occurrence
                    FROM public.{table} AS movement
                    INNER JOIN public.bank_accounts_d AS account ON account.account_id = movement.account_id
                    ORDER BY movement.row_id
                    """
                ).fetchall()
                assert [row[0] for row in rows] == [row[0] for row in old[table]]
                assert len({row[1] for row in rows}) == len(rows)
                for _, row_hash, uid, acc, bank, account_bank, txn, sk, abonos, cargos, occ in rows:
                    assert bank == account_bank
                    assert row_hash == movement_row_hash_v2(uid, acc, bank, txn, sk, abonos, cargos, occ)
                    if kind == "debit":
                        assert cargos <= 0 <= abonos
                    else:
                        assert cargos >= 0 and abonos >= 0
                assert not {h for _, h in old[table]} & {row[1] for row in rows}
                assert conn.execute(
                    "SELECT convalidated FROM pg_constraint WHERE conname = %s", (f"{table}_sign_check",)
                ).fetchone() == (True,)
            credit_closed = conn.execute(
                "SELECT occurrence FROM public.master_credit_closed_f ORDER BY occurrence"
            ).fetchall()
            assert credit_closed == [(1,), (2,)]
            master_hashes = {h for table in first.values() for _, h in table}
            dims = {row[0] for row in conn.execute("SELECT row_hash FROM public.movement_dimensions_d").fetchall()}
            assert dims == master_hashes
            assert len(dims) == old_dims
            view = conn.execute(
                "SELECT layer, kind, COUNT(*) FROM public.movement_keys_v GROUP BY 1, 2 ORDER BY 1, 2"
            ).fetchall()
            assert view == [("closed", "credit", 2), ("closed", "debit", 3), ("future", "credit", 8),
                            ("open", "credit", 2), ("open", "debit", 3)]

            # The ingest after 014 makes the same key the migration made.
            _session(conn, user_id, tenant_id)
            _ingest(conn, debit_id, _current(conn, debit_id, MSI_AS_OF)["cutoff_id"],
                    "statement", "0639.csv", OPEN_DEBIT_CSV, MSI_AS_OF)
            reloaded = conn.execute(
                "SELECT row_hash FROM public.master_debit_open_f ORDER BY row_hash"
            ).fetchall()
            assert {row[0] for row in reloaded} == {h for _, h in first["master_debit_open_f"]}
            # The sign rule is enforced for new rows.
            _expect_error(
                conn,
                "UPDATE public.master_debit_open_f SET cargos = 5, amount = 5 + abonos WHERE row_id = "
                "(SELECT MIN(row_id) FROM public.master_debit_open_f)",
                (),
                "master_debit_open_f_sign_check",
            )
            # Row level security applies through the view.
            other, other_tenant = _user(conn, "rehash-other@example.com")
            _session(conn, other, other_tenant)
            conn.execute("SET ROLE strm_app")
            assert conn.execute("SELECT COUNT(*) FROM public.movement_keys_v").fetchone()[0] == 0
            conn.execute("RESET ROLE")
            _session(conn, user_id, tenant_id)
            conn.execute("SET ROLE strm_app")
            assert conn.execute("SELECT COUNT(*) FROM public.movement_keys_v").fetchone()[0] == 18
            conn.execute("RESET ROLE")
            conn.rollback()

        # Re-running 011 recreates an empty master_debit_future_f; 014 drops it again.
        _apply_files(url, ("011_open_future_ledgers.sql", "014_normalized_row_hash.sql"), **kw)
        with psycopg.connect(url) as conn:
            assert conn.execute("SELECT TO_REGCLASS('public.master_debit_future_f')").fetchone()[0] is None
            assert _master_snapshot(conn) == first
            assert conn.execute("SELECT COUNT(*) FROM public.movement_dimensions_d").fetchone()[0] == old_dims
    finally:
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.close()
