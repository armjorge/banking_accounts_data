"""sql/018: one column layout for every master table, opening balances and monthly
adjustments for any account, banks users add / rename / move accounts to, and the column
map wizard for statement uploads."""

from __future__ import annotations

import json
import uuid
from datetime import date
from decimal import Decimal

import psycopg
import pytest
from config_console.postgres_ops import _apply_files, apply_banking_ddl, migration_plan
from statements.rules import concept_sk, movement_row_hash_v2
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
    _premium,
    _session,
    _user,
)

MASTERS = (
    "master_debit_closed_f",
    "master_debit_open_f",
    "master_credit_closed_f",
    "master_credit_open_f",
    "master_credit_future_f",
    "master_closed_aaccandass_f",
)
STANDARD = [
    "row_id", "file_id", "tenant_id", "user_id", "account_id", "bank_id", "cutoff_id",
    "txn_date", "concept", "abonos", "cargos", "amount", "concept_sk", "row_hash",
]
KW = {"users_schema": "cognito_users", "database": "neondb", "app_schema": "public"}
# A bank layout no built-in profile knows: one signed amount column.
ODD_CSV = (
    "Fecha operación,Descripción,Referencia,Importe,Saldo\n"
    "02/09/2026,Pago tarjeta,R1,-1200.50,8799.50\n"
    "05/09/2026,Nómina,R2,15000.00,23799.50\n"
    "05/09/2026,Café,R3,-45.00,23754.50\n"
)
ODD_MAP = {"txn_date": "Fecha operación", "concept": "Descripción || ' ' || Referencia",
           "abono": "Importe", "cargo": "Importe"}


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


def _one(conn, sql, params=()):
    return _json(conn.execute(sql, params).fetchone()[0])


def _owner(conn, email):
    user_id, tenant_id = _user(conn, email)
    _session(conn, user_id, tenant_id)
    _premium(conn, tenant_id)
    return user_id, tenant_id


def _columns(conn, table):
    return [row[0] for row in conn.execute(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' "
        "AND table_name = %s ORDER BY ordinal_position", (table,)
    ).fetchall()]


def _shown(conn, account_id, as_of="2027-12-31"):
    return Decimal(str(_one(conn, "SELECT public.account_balance_home(%s, %s)", (account_id, as_of))["balance"]))


# --- layout ------------------------------------------------------------------------------


def test_every_master_has_the_standard_columns(conn):
    for table in (*MASTERS, "master_open_aaccandass_f"):
        columns = _columns(conn, table)
        assert columns[:14] == STANDARD, table
        assert not {"file_name", "source_profile", "account_number", "bank_name", "period_start"} & set(columns)
        generated = conn.execute(
            "SELECT is_generated, generation_expression FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = %s AND column_name = 'amount'", (table,)
        ).fetchone()
        expr = generated[1].replace(" ", "")
        if table.startswith("master_debit"):
            assert generated[0] == "ALWAYS" and "abonos+cargos" in expr
        else:
            assert generated[0] == "ALWAYS" and "abonos-cargos" in expr
        assert "saldos" not in columns and "tarjeta" not in columns
        fk = conn.execute(
            "SELECT COUNT(*) FROM pg_constraint WHERE conrelid = %s::regclass AND contype = 'f' "
            "AND confrelid = 'public.cutoff_date_f'::regclass", (f"public.{table}",)
        ).fetchone()[0]
        assert fk == 1, table


def test_concept_sk_mirror_folds_case_and_accents(conn):
    for text in ("Café Ñandú", "PAYPAL *SHOP 150323", "  abono  por trasp. ", "Nómina", "", "123-45"):
        assert conn.execute("SELECT public.concept_sk(%s)", (text,)).fetchone()[0] == concept_sk(text), text
    assert concept_sk("Café Ñandú") == "CAFENANDU"
    assert concept_sk("PAYPAL *SHOP 150323") == "150323"


def test_migration_plan_replaces_006_to_017_on_the_new_layout():
    names = ("006_statement_flow.sql", "010_x.sql", "017_investments_assets.sql")
    assert migration_plan(names, False) == names
    assert migration_plan(names, True) == ("018_standard_masters_balances_banks.sql",)
    assert migration_plan(("001_x.sql",), True) == ("001_x.sql",)


# --- the rebuild keeps every row, attribute and link -----------------------------------


def _net(conn, before):
    # Debit amount is abonos + cargos (cargos stay negative). Credit and assets are abonos - cargos.
    if before:
        sql = """
            SELECT account_id, SUM(abonos + cargos) FROM public.master_debit_closed_f GROUP BY 1
            UNION ALL SELECT account_id, SUM(abonos + cargos) FROM public.master_debit_open_f GROUP BY 1
            UNION ALL SELECT account_id, SUM(abonos - cargos) FROM public.master_credit_closed_f GROUP BY 1
            UNION ALL SELECT account_id, SUM(abonos - cargos) FROM public.master_credit_open_f GROUP BY 1
            UNION ALL SELECT account_id, SUM(abonos - cargos) FROM public.master_credit_future_f GROUP BY 1
            UNION ALL SELECT account_id, SUM(abonos - cargos) FROM public.master_closed_aaccandass_f GROUP BY 1
        """
    else:
        sql = " UNION ALL ".join(f"SELECT account_id, SUM(amount) FROM public.{t} GROUP BY 1" for t in MASTERS)
    out: dict[int, Decimal] = {}
    for account_id, total in conn.execute(sql).fetchall():
        out[account_id] = out.get(account_id, Decimal(0)) + total
    return out


def _counts(conn):
    rows = {t: conn.execute(f"SELECT COUNT(*) FROM public.{t}").fetchone()[0] for t in MASTERS}
    attrs = {
        t: conn.execute(f"SELECT COUNT(*) FROM public.{t} WHERE attribute_1_item_id IS NOT NULL").fetchone()[0]
        for t in ("debit_d", "credit_d", "master_closed_aaccandass_d")
    }
    links = conn.execute("SELECT status, COUNT(*) FROM public.inter_accounts_d GROUP BY 1 ORDER BY 1").fetchall()
    return rows, attrs, links


def test_018_rebuild_keeps_rows_attributes_links_and_balances():
    admin = _admin()
    name = f"strm_{uuid.uuid4().hex[:10]}"
    admin.execute(f'CREATE DATABASE "{name}"')
    url = f"postgresql:///{name}?sslmode=disable"
    try:
        apply_banking_ddl(url, users_schema="cognito_users", database="neondb")
        before_018 = LATER_MIGRATIONS[: LATER_MIGRATIONS.index("018_standard_masters_balances_banks.sql")]
        _apply_files(url, before_018, **KW)
        with psycopg.connect(url) as conn:
            user_id, tenant_id = _owner(conn, "rebuild@example.com")
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
            # One attribute on a debit row (its hash changes) and one manual link.
            spei = conn.execute(
                "SELECT row_hash FROM public.master_debit_open_f WHERE concept LIKE 'SPEI%%'"
            ).fetchone()[0]
            conn.execute("SELECT public.save_dimension(%s, 'Rent', NULL, NULL)", (spei,))
            payment = conn.execute(
                "SELECT row_hash FROM public.master_credit_open_f WHERE abonos > 0"
            ).fetchone()[0]
            conn.execute("SELECT public.link_transfer(%s, %s)", (spei, payment))
            before = _counts(conn)
            net_before = _net(conn, True)
            conn.commit()

        applied = _apply_files(url, ("018_standard_masters_balances_banks.sql",), **KW)
        assert applied == ["018_standard_masters_balances_banks.sql"]
        with psycopg.connect(url) as conn:
            after = _counts(conn)
            assert after == before
            assert _net(conn, False) == net_before
            for table in MASTERS:
                assert _columns(conn, table)[:14] == STANDARD
            # Debit cargos stay negative. This concept's key is its digits, so the hash stays.
            row = conn.execute(
                "SELECT row_hash, txn_date, concept_sk, abonos, cargos, occurrence, amount "
                "FROM public.master_debit_open_f WHERE concept LIKE 'SPEI%%'"
            ).fetchone()
            assert row[4] == Decimal("-250.00") and row[6] == Decimal("-250.00")
            bank_id = conn.execute(
                "SELECT bank_id FROM public.bank_accounts_d WHERE account_id = %s", (debit_id,)
            ).fetchone()[0]
            assert row[0] == movement_row_hash_v2(str(user_id), debit_id, bank_id, *row[1:6])
            assert row[0] == spei
            _session(conn, user_id, tenant_id)
            moved = _one(conn, "SELECT public.dimension_rows('debit', 'open')")["rows"]
            assert next(item for item in moved if item["row_hash"] == row[0])["attribute_1"] == "Rent"
            link = conn.execute(
                "SELECT sending_hash, receiving_hash, link_hash FROM public.inter_accounts_d WHERE source = 'manual'"
            ).fetchone()
            assert link[0] == row[0]
            assert link[2] == conn.execute(
                "SELECT public.transfer_link_hash(%s, %s)", (link[0], link[1])
            ).fetchone()[0]
            # Every row points at a period; file name and profile come through file_id.
            keys = conn.execute(
                "SELECT COUNT(*), COUNT(cutoff_id), COUNT(file_name), COUNT(source_profile) FROM public.movement_keys_v"
            ).fetchone()
            assert keys[0] == keys[1] == keys[2] == keys[3] == sum(before[0].values())
            conn.commit()

        # Applying again (and the full DDL) changes nothing; 018b drops the unused tables and
        # nothing re-creates them.
        _apply_files(url, ("018b_drop_unused.sql",), **KW)
        again = _apply_all_ddl(url, skip_clear=True)
        assert "006_statement_flow.sql" not in again and "018_standard_masters_balances_banks.sql" in again
        with psycopg.connect(url) as conn:
            assert _counts(conn) == before
            assert _net(conn, False) == net_before
            assert conn.execute(
                "SELECT TO_REGCLASS('public.movement_dimensions_d'), TO_REGCLASS('public.open_debit_f'), "
                "TO_REGCLASS('public.bank_templates_f'), TO_REGCLASS('public.credit_plan_closed_f')"
            ).fetchone() == (None, None, None, "credit_plan_closed_f")
            _session(conn, user_id, tenant_id)
            for upload_id in [r[0] for r in conn.execute("SELECT upload_id FROM public.statement_uploads_f").fetchall()]:
                conn.execute("SELECT public.delete_statement_upload(%s)", (upload_id,))
            assert sum(_counts(conn)[0].values()) == 0
            conn.rollback()
    finally:
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.close()


# --- opening balance and monthly reconciliation --------------------------------------


def test_opening_balance_and_reconcile_on_debit(conn):
    _owner(conn, "opening-debit@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
    home = _one(conn, "SELECT public.account_balance_home(%s, %s)", (debit_id, MSI_AS_OF))
    assert home["first_txn_date"] == "2025-10-03" and home["default_opening_date"] == "2025-10-02"
    assert Decimal(str(home["balance"])) == Decimal("372.20")
    _expect_error(conn, "SELECT public.add_opening_balance(%s, 100, '2025-10-03')", (debit_id,),
                  "before the first movement", "22023")
    opened = _one(conn, "SELECT public.add_opening_balance(%s, 100, NULL, NULL, 'from paper')", (debit_id,))
    assert opened["txn_date"] == "2025-10-02" and Decimal(str(opened["balance"])) == Decimal("472.20")
    row = conn.execute(
        "SELECT entry_source, file_id, abonos, cargos, concept, note, cutoff_id IS NOT NULL "
        "FROM public.master_debit_closed_f WHERE row_hash = %s", (opened["row_hash"],)
    ).fetchone()
    assert row == ("opening", None, Decimal("100.00"), Decimal("0.00"), "Saldo inicial", "from paper", True)
    _expect_error(conn, "SELECT public.add_opening_balance(%s, 5, '2020-01-01')", (debit_id,),
                  "already has an opening balance", "23505")
    # The bank shows 500.00 at month end: one adjustment of 27.80.
    check = _one(conn, "SELECT public.reconcile_account(%s, '2025-10-31', 500)", (debit_id,))
    assert Decimal(str(check["tracked_balance"])) == Decimal("472.20")
    assert Decimal(str(check["adjustment"]["abonos"])) == Decimal("27.80")
    assert _shown(conn, debit_id) == Decimal("500.00")
    same = _one(conn, "SELECT public.reconcile_account(%s, '2025-10-31', 500)", (debit_id,))
    assert same["adjustment"] is None
    # Uploaded rows cannot be deleted one by one; balance rows can.
    upload_hash = conn.execute(
        "SELECT row_hash FROM public.master_debit_closed_f WHERE entry_source = 'upload' LIMIT 1"
    ).fetchone()[0]
    _expect_error(conn, "SELECT public.delete_balance_row(%s)", (upload_hash,),
                  "Only an opening or adjustment row can be changed here", "22023")
    _one(conn, "SELECT public.delete_balance_row(%s)", (check["adjustment"]["row_hash"],))
    assert _shown(conn, debit_id) == Decimal("472.20")
    # Statement completeness is untouched by balance rows.
    assert _period(conn, debit_id, "2026-10", MSI_AS_OF)["pending"] is False


def test_opening_balance_and_reconcile_on_credit_card(conn):
    _owner(conn, "opening-credit@example.com")
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    _ingest(conn, credit_id, _period(conn, credit_id, "2026-11", MSI_AS_OF)["cutoff_id"],
            "statement", "3978.csv", CREDIT_CSV, MSI_AS_OF)
    assert _shown(conn, credit_id) == Decimal("40.00")  # owed
    opened = _one(conn, "SELECT public.add_opening_balance(%s, 1000)", (credit_id,))
    row = conn.execute(
        "SELECT abonos, cargos, amount FROM public.master_credit_closed_f WHERE row_hash = %s", (opened["row_hash"],)
    ).fetchone()
    assert row == (Decimal("0.00"), Decimal("1000.00"), Decimal("-1000.00"))
    assert _shown(conn, credit_id) == Decimal("1040.00")
    check = _one(conn, "SELECT public.reconcile_account(%s, '2025-10-31', 1000)", (credit_id,))
    assert Decimal(str(check["difference"])) == Decimal("-40.00")
    assert Decimal(str(check["adjustment"]["abonos"])) == Decimal("40.00")
    assert Decimal(str(_one(conn, "SELECT public.account_balance_home(%s, '2025-10-31')", (credit_id,))["balance"])) \
        == Decimal("1000.00")
    # Balance rows never enter transfer detection.
    assert conn.execute(
        "SELECT COUNT(*) FROM public.transfer_pool(public.session_tenant(), public.session_user()) "
        "WHERE row_hash = %s", (opened["row_hash"],)
    ).fetchone()[0] == 0


def test_opening_balance_on_asset_account(conn):
    _owner(conn, "opening-asset@example.com")
    institution = conn.execute("SELECT bank_id FROM public.banks_d WHERE bank_name = 'Infonavit'").fetchone()[0]
    type_id = conn.execute("SELECT a_type_id FROM public.account_types_d WHERE type_name = 'Savings, investments, assets, credit contracts'").fetchone()[0]
    account_id = _one(conn, "SELECT public.create_asset_account(%s, NULL, %s, 'Vivienda', NULL)",
                      (institution, type_id))["account_id"]
    _expect_error(conn, "SELECT public.add_opening_balance(%s, 10)", (account_id,), "Pick the opening date", "22023")
    _one(conn, "SELECT public.add_opening_balance(%s, 1500, '2026-01-31')", (account_id,))
    assert _shown(conn, account_id) == Decimal("1500.00")
    assert conn.execute(
        "SELECT entry_source FROM public.master_closed_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchall() == [("opening",)]


# --- banks -------------------------------------------------------------------------------


def test_banks_add_rename_and_move_account_remaps(conn):
    user_id, tenant = _owner(conn, "banks@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
    old = conn.execute(
        "SELECT row_hash FROM public.master_debit_closed_f WHERE account_id = %s ORDER BY row_id LIMIT 1", (debit_id,)
    ).fetchone()[0]
    conn.execute("SELECT public.save_dimension(%s, 'Shop', NULL, NULL)", (old,))
    _expect_error(conn, "SELECT public.create_bank('x', FALSE)", (), "2 to 60 characters", "22023")
    _expect_error(conn, "SELECT public.create_bank('banorte', FALSE)", (), "already exists", "23505")
    bank = _one(conn, "SELECT public.create_bank('  Banco   Azul ', FALSE)")
    assert bank["bank_name"] == "Banco Azul"
    renamed = _one(conn, "SELECT public.rename_bank(%s, 'Banco Azteca Azul')", (bank["bank_id"],))
    assert renamed["previous_name"] == "Banco Azul"
    _expect_error(conn, "SELECT public.rename_bank((SELECT bank_id FROM public.banks_d WHERE bank_name = 'Banorte'), "
                  "'Mine')", (), "built-in statement profile", "42501")
    # A bank another customer uses cannot be renamed by one of them.
    other_user, other_tenant = _user(conn, "banks-other@example.com")
    _session(conn, other_user, other_tenant)
    conn.execute(
        "SELECT public.create_bank_account(%s, (SELECT a_type_id FROM public.account_types_d "
        "WHERE LOWER(type_name) = 'bank debit'), 'Azul', '4321', NULL, NULL, %s)", (bank["bank_id"], MSI_AS_OF),
    )
    _session(conn, user_id, tenant)
    _expect_error(conn, "SELECT public.rename_bank(%s, 'Banco Rojo')", (bank["bank_id"],), "Other customers", "42501")
    catalog = _one(conn, "SELECT public.bank_catalog()")
    mine = next(item for item in catalog if item["bank_id"] == bank["bank_id"])
    assert mine["can_rename"] is False and mine["has_profile"] is False

    moved = _one(conn, "SELECT public.set_account_bank(%s, %s)", (debit_id, bank["bank_id"]))
    assert moved["rows_rekeyed"] == 3
    rows = conn.execute(
        "SELECT row_hash, bank_id, txn_date, concept_sk, abonos, cargos, occurrence FROM public.master_debit_closed_f "
        "WHERE account_id = %s", (debit_id,)
    ).fetchall()
    assert {row[1] for row in rows} == {bank["bank_id"]}
    for row in rows:
        assert row[0] == movement_row_hash_v2(str(user_id), debit_id, bank["bank_id"], *row[2:7])
    new = conn.execute("SELECT new_hash FROM public.row_hash_remap_f WHERE old_hash = %s", (old,)).fetchone()[0]
    attrs = _one(conn, "SELECT public.dimension_rows('debit', 'closed')")["rows"]
    assert next(item for item in attrs if item["row_hash"] == new)["attribute_1"] == "Shop"
    assert conn.execute("SELECT COUNT(*) FROM public.debit_d WHERE row_hash = %s", (old,)).fetchone()[0] == 0
    # Statement uploads keep working on the new bank (Banorte layout is still recognised).
    home = _one(conn, "SELECT public.statement_home(%s)", (MSI_AS_OF,))
    assert next(item for item in home["accounts"] if item["account_id"] == debit_id)["bank_name"] == "Banco Azteca Azul"


def test_delete_bank_is_limited_to_its_creator_and_blocks_on_accounts(conn):
    user_id, tenant = _owner(conn, "remove-bank@example.com")
    free = _one(conn, "SELECT public.create_bank('Banco Libre', FALSE)")
    stored = conn.execute(
        "SELECT tenant_id, created_by FROM public.banks_d WHERE bank_id = %s", (free["bank_id"],)
    ).fetchone()
    assert stored == (tenant, user_id)
    catalog = _one(conn, "SELECT public.bank_catalog()")
    listed = next(item for item in catalog if item["bank_id"] == free["bank_id"])
    assert listed["can_remove"] is True and listed["remove_block"] is None
    banorte = next(item for item in catalog if item["bank_name"] == "Banorte")
    assert banorte["can_remove"] is False and banorte["remove_block"] is None
    _expect_error(
        conn, "SELECT public.delete_bank(%s)", (banorte["bank_id"],),
        "Only a bank you added can be removed", "42501",
    )

    busy = _one(conn, "SELECT public.create_bank('Banco Ocupado', FALSE)")
    conn.execute(
        "SELECT public.create_bank_account(%s, (SELECT a_type_id FROM public.account_types_d "
        "WHERE LOWER(type_name) = 'bank debit'), 'Ocupada', '7777', NULL, NULL, %s)",
        (busy["bank_id"], MSI_AS_OF),
    )
    _expect_error(
        conn, "SELECT public.delete_bank(%s)", (busy["bank_id"],),
        "Move or delete its accounts first", "42501",
    )
    blocked = next(item for item in _one(conn, "SELECT public.bank_catalog()") if item["bank_id"] == busy["bank_id"])
    assert blocked["can_remove"] is False
    assert blocked["remove_block"] == "Move or delete its accounts first"

    other_user, other_tenant = _user(conn, "remove-bank-other@example.com")
    _session(conn, other_user, other_tenant)
    _expect_error(
        conn, "SELECT public.delete_bank(%s)", (free["bank_id"],),
        "Only a bank you added can be removed", "42501",
    )
    theirs = _one(conn, "SELECT public.create_bank('Banco Ajeno', FALSE)")
    _session(conn, user_id, tenant)
    removed = _one(conn, "SELECT public.delete_bank(%s)", (free["bank_id"],))
    assert removed["bank_name"] == "Banco Libre"
    assert conn.execute("SELECT COUNT(*) FROM public.banks_d WHERE bank_id = %s", (free["bank_id"],)).fetchone()[0] == 0

    # strm_app's own DELETE is the RLS policy: this tenant and this user only.
    spare = _one(conn, "SELECT public.create_bank('Banco Suelto', FALSE)")
    conn.execute("SET LOCAL ROLE strm_app")
    assert conn.execute("DELETE FROM public.banks_d WHERE bank_name = 'Banorte'").rowcount == 0
    assert conn.execute("DELETE FROM public.banks_d WHERE bank_id = %s", (theirs["bank_id"],)).rowcount == 0
    assert conn.execute("DELETE FROM public.banks_d WHERE bank_id = %s", (spare["bank_id"],)).rowcount == 1
    conn.execute("RESET ROLE")


# --- column map wizard -------------------------------------------------------------------


def test_column_map_wizard_saves_and_reuses_the_map(conn):
    _owner(conn, "wizard@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    cutoff = _period(conn, debit_id, "2026-09", MSI_AS_OF)["cutoff_id"]
    _expect_error(
        conn, "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'odd.csv', %s, %s)",
        (debit_id, cutoff, ODD_CSV, MSI_AS_OF), "map the columns", "22P02",
    )
    preview = _one(conn, "SELECT public.column_map_preview(%s, %s, %s::jsonb)", (debit_id, ODD_CSV, json.dumps(ODD_MAP)))
    assert preview["ready"] is True and preview["kind"] == "debit"
    assert preview["saved_mapping"] is None
    loaded = _one(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'odd.csv', %s, %s, NULL, NULL, %s::jsonb, 'Azul')",
        (debit_id, cutoff, ODD_CSV, MSI_AS_OF, json.dumps(ODD_MAP)),
    )
    assert loaded["row_count"] == 3 and loaded["profile"] == "column_map" and loaded["column_map_id"]
    rows = conn.execute(
        "SELECT txn_date, concept, abonos, cargos, amount FROM public.master_debit_closed_f "
        "WHERE account_id = %s ORDER BY txn_date, row_id", (debit_id,)
    ).fetchall()
    assert rows[0] == (date(2026, 9, 2), "Pago tarjeta R1", Decimal("0.00"), Decimal("-1200.50"), Decimal("-1200.50"))
    assert rows[1][2:] == (Decimal("15000.00"), Decimal("0.00"), Decimal("15000.00"))
    # Next month: same header, no mapping sent; the saved map is found by its signature.
    later = _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"]
    october = ODD_CSV.replace("/09/2026", "/10/2026")
    again = _one(conn, "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'oct.csv', %s, %s)",
                 (debit_id, later, october, MSI_AS_OF))
    assert again["row_count"] == 3 and again["column_map_id"] == loaded["column_map_id"]
    found = _one(conn, "SELECT public.column_map_preview(%s, %s, NULL)", (debit_id, october))
    assert found["saved_mapping"]["template_id"] == loaded["column_map_id"]
    # Installment plans keep their own parser.
    _expect_error(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'installment', 'x.csv', %s, %s, NULL, NULL, %s::jsonb, NULL)",
        (debit_id, cutoff, ODD_CSV, MSI_AS_OF, json.dumps(ODD_MAP)), "", None,
    )


def test_018b_is_separate_and_main_018_drops_no_table():
    from pathlib import Path

    sql = Path(__file__).resolve().parents[3] / "sql"
    main = (sql / "018_standard_masters_balances_banks.sql").read_text(encoding="utf-8").upper()
    drops = [line for line in main.splitlines() if "DROP TABLE" in line and not line.strip().startswith("--")]
    # Only the rebuilt copies swap places with the old tables (data is copied first).
    assert all("%I" in line or "PG_TEMP." in line for line in drops), drops
    extra = (sql / "018b_drop_unused.sql").read_text(encoding="utf-8")
    assert "DROP TABLE" in extra.upper()


# --- API -----------------------------------------------------------------------------------


def test_local_api_018_routes_as_app_role(conn):
    from statements.local_api import dispatch_018

    _owner(conn, "routes-018@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
    conn.execute("SET LOCAL ROLE strm_app")
    with conn.cursor() as cur:

        def route(method, path, body=None, **params):
            return dispatch_018(cur, method, path, {key: [str(value)] for key, value in params.items()}, lambda: body or {})

        status, home = route("GET", f"/balances/{debit_id}", as_of="2026-11-13")
        assert status == 200 and home["default_opening_date"] == "2025-10-02"
        assert route("POST", "/balances/opening", {"account_id": debit_id, "balance": "abc"})[0] == 400
        opened = route("POST", "/balances/opening", {"account_id": debit_id, "balance": "1,000"})[1]
        assert Decimal(str(opened["balance"])) == Decimal("1372.20")
        check = route("POST", "/balances/reconcile",
                      {"account_id": debit_id, "as_of": "2025-10-31", "reported_balance": "1400"})[1]
        assert Decimal(str(check["adjustment"]["abonos"])) == Decimal("27.80")
        assert route("DELETE", f"/balances/rows/{check['adjustment']['row_hash']}")[1]["deleted"] is True
        assert route("DELETE", "/balances/rows/nothex")[0] == 400
        bank = route("POST", "/banks", {"bank_name": "Banco Verde"})[1]
        assert route("POST", f"/banks/{bank['bank_id']}", {"bank_name": "Banco Verde MX"})[1]["bank_name"] == "Banco Verde MX"
        spare = route("POST", "/banks", {"bank_name": "Banco Borrar"})[1]
        assert route("DELETE", f"/banks/{spare['bank_id']}")[1]["bank_name"] == "Banco Borrar"
        listed = route("GET", "/banks")[1]
        assert any(item["bank_id"] == bank["bank_id"] for item in listed)
        assert all(item["bank_id"] != spare["bank_id"] for item in listed)
        moved = route("POST", f"/accounts/{debit_id}/bank", {"bank_id": bank["bank_id"]})[1]
        assert moved["rows_rekeyed"] == 4
        preview = route("POST", "/statements/preview", {"account_id": debit_id, "csv": ODD_CSV, "mapping": ODD_MAP})[1]
        assert preview["ready"] is True
        assert route("GET", "/assets") is None


def test_018_routes_match_in_lambda_stack_and_local_api():
    from pathlib import Path

    root = Path(__file__).resolve().parents[3]
    stack = (root / "infra" / "lib" / "environment-stack.ts").read_text(encoding="utf-8")
    lambda_ts = (root / "infra" / "lambda" / "statements.ts").read_text(encoding="utf-8")
    local = (root / "apps" / "statements" / "local_api.py").read_text(encoding="utf-8")
    for method, path in (
        ("GET", "/balances/{accountId}"), ("POST", "/balances/opening"), ("POST", "/balances/reconcile"),
        ("POST", "/balances/rows/{rowHash}"), ("DELETE", "/balances/rows/{rowHash}"),
        ("GET", "/banks"), ("POST", "/banks"), ("POST", "/banks/{bankId}"),
        ("DELETE", "/banks/{bankId}"), ("DELETE", "/accounts/{accountId}"),
        ("POST", "/accounts/{accountId}/bank"), ("POST", "/statements/preview"),
    ):
        line = next(line for line in stack.splitlines() if f'["{path}", [' in line)
        assert f"HttpMethod.{method}" in line, (method, path)
    for fn in ("account_balance_home", "add_opening_balance", "reconcile_account", "delete_balance_row",
               "bank_catalog", "create_bank", "rename_bank", "delete_bank", "set_account_bank",
               "column_map_preview", "update_balance_row", "delete_bank_account"):
        assert f"public.{fn}(" in lambda_ts and f"public.{fn}(" in local, fn
    assert "$10::jsonb, $11" in lambda_ts and "%s::jsonb, %s" in local
    assert "CorsHttpMethod.POST" in stack
    assert "GET, POST, DELETE, OPTIONS" in local


def test_web_pages_018():
    from pathlib import Path

    web = Path(__file__).resolve().parents[3] / "web"
    master = (web / "master.js").read_text(encoding="utf-8")
    assert "data-admin" not in master and "drawDataAdmin" not in master and '"/admin' not in master
    statements = (web / "statements.js").read_text(encoding="utf-8")
    for needle in ("strmColumnMapWizard(", "/balances/opening", "/balances/reconcile", "/accounts/${accountId}/bank",
                   '"/banks"', "map the columns", 'type="button" data-rename-bank=',
                   "data-banks-status", "data-move-status", "showBanks(error.message, true)",
                   "This bank has a built-in statement profile; its name stays as it is.",
                   "Other customers have accounts at this bank; it cannot be renamed here.",
                       "Bank renamed.", "Bank added.", "Account moved.", "Bank removed.",
                       "Remove bank", "remove_block",
                       "Remove ${name}? This cannot be undone.",
                       'button[data-rename-bank]', 'data-remove-bank=', 'method: "DELETE"',
                       "data-save-balance-row", "Balance row saved.", "result.target_table"):
        assert needle in statements, needle
    sql = (web.parent / "sql" / "018_standard_masters_balances_banks.sql").read_text(encoding="utf-8")
    assert "Move or delete its accounts first" in sql
    assert "CREATE POLICY banks_d_delete" in sql
    column_map = (web / "column_map.js").read_text(encoding="utf-8")
    assert '"/statements/preview"' in column_map
    assert "positive cargo" in column_map
    assert "target_table" in (web / "assets.js").read_text(encoding="utf-8")
    assert "!bank.is_institution" not in statements
    dims = (web / "dimensions.js").read_text(encoding="utf-8")
    assert "<td>${dimEsc(row.concept)}" in dims and "<th>Concept</th><th>Key</th>" in dims
    assert "/balances/opening" in (web / "assets.js").read_text(encoding="utf-8")
    for page in ("index.html", "preview.html"):
        html = (web / page).read_text(encoding="utf-8")
        assert html.index("column_map.js") < html.index("statements.js")


ASSET_CSV = "Fecha,Concepto,Importe\n02/09/2026,CETES EGREFVO,-188000\n"
ASSET_MAP = {"txn_date": "Fecha", "concept": "Concepto", "amount": "Importe"}
DEPOSIT_CSV = "Fecha,Concepto,Importe\n02/09/2026,Deposito CETES,188000\n"
DEPOSIT_MAP = {"txn_date": "Fecha", "concept": "Concepto", "amount": "Importe"}


def test_asset_upload_signs_transfers_banks_and_balance_edit(conn):
    from test_investments_assets import _asset_account

    _owner(conn, "asset-route@example.com")
    _one(conn, "SELECT public.create_bank('NAFINSA')")
    asset_id = _asset_account(conn, "NAFINSA", "CETES", "816089")
    cutoff = conn.execute(
        "SELECT public.month_cutoff_id(public.session_tenant(), public.session_user(), %s, DATE '2026-09-02')",
        (asset_id,),
    ).fetchone()[0]
    preview = _one(
        conn, "SELECT public.column_map_preview(%s, %s, %s::jsonb)", (asset_id, ASSET_CSV, json.dumps(ASSET_MAP))
    )
    assert preview["kind"] == "asset" and preview["cargo_sign"] == "positive"
    assert Decimal(str(preview["rows"][0]["cargos"])) == Decimal("188000.00")
    assert Decimal(str(preview["rows"][0]["abonos"])) == Decimal("0.00")

    loaded = _one(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', 'cetes.csv', %s, %s, NULL, NULL, %s::jsonb, NULL)",
        (asset_id, cutoff, ASSET_CSV, MSI_AS_OF, json.dumps(ASSET_MAP)),
    )
    assert loaded["target_table"] == "master_closed_aaccandass_f"
    assert loaded["inserted"] == 1
    assert conn.execute(
        "SELECT COUNT(*) FROM public.master_debit_open_f WHERE account_id = %s", (asset_id,)
    ).fetchone()[0] == 0
    stored = conn.execute(
        "SELECT cargos, abonos FROM public.master_closed_aaccandass_f WHERE account_id = %s", (asset_id,)
    ).fetchone()
    assert stored == (Decimal("188000.00"), Decimal("0.00"))
    assert conn.execute(
        "SELECT COUNT(*) FROM public.master_closed_aaccandass_d WHERE account_id = %s", (asset_id,)
    ).fetchone()[0] == 1

    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    debit_cutoff = _period(conn, debit_id, "2026-09", MSI_AS_OF)["cutoff_id"]
    _one(
        conn,
        "SELECT public.ingest_statement_csv(%s, %s, 'statement', '0639.csv', %s, %s, NULL, NULL, %s::jsonb, NULL)",
        (debit_id, debit_cutoff, DEPOSIT_CSV, MSI_AS_OF, json.dumps(DEPOSIT_MAP)),
    )
    link = conn.execute(
        """SELECT link.amount
        FROM public.inter_accounts_d AS link
        WHERE link.sending_account_id = %s AND link.receiving_account_id = %s AND link.status = 'active'""",
        (asset_id, debit_id),
    ).fetchone()
    assert link is not None and Decimal(str(link[0])) == Decimal("188000.00")

    home = _one(conn, "SELECT public.statement_home(%s)", (MSI_AS_OF,))
    names = {bank["bank_name"] for bank in home["banks"]}
    assert {"GBM", "Infonavit", "NAFINSA", "Banorte"} <= names
    _expect_error(conn, "SELECT public.create_bank('GBM')", (), "That bank already exists", "23505")

    _one(conn, "SELECT public.add_opening_balance(%s, 100)", (debit_id,))
    row_hash = conn.execute(
        "SELECT row_hash FROM public.movement_keys_v WHERE account_id = %s AND entry_source = 'opening'",
        (debit_id,),
    ).fetchone()[0]
    edited = _one(conn, "SELECT public.update_balance_row(%s, DATE '2026-08-31', 80)", (row_hash,))
    assert Decimal(str(edited["amount"])) == Decimal("80.00")
    assert edited["balance"] is not None
    upload_hash = conn.execute(
        "SELECT row_hash FROM public.movement_keys_v WHERE account_id = %s AND entry_source = 'upload' LIMIT 1",
        (debit_id,),
    ).fetchone()[0]
    _expect_error(
        conn, "SELECT public.update_balance_row(%s, DATE '2026-09-02', 1)", (upload_hash,),
        "Only an opening or adjustment row can be changed here", "22023",
    )
    deleted = _one(conn, "SELECT public.delete_balance_row(%s)", (edited["row_hash"],))
    assert deleted["deleted"] is True and "balance" in deleted


def test_graphql_keeps_field_names_and_adds_entry_source(conn, database_url):
    from test_dimensions_graphql import _gql, _token

    _owner(conn, "gql-018@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-10", MSI_AS_OF)["cutoff_id"],
            "statement", "0639.csv", DEBIT_CSV, MSI_AS_OF)
    _one(conn, "SELECT public.add_opening_balance(%s, 100)", (debit_id,))
    token = _token(conn)["token"]
    conn.commit()
    status, payload, _ = _gql(
        database_url, token,
        "{ movements(kind: DEBIT, layer: CLOSED, months: 36) { txn_date concept file_name source_profile "
        "entry_source cutoff_id cargos amount balance } }",
    )
    assert status == 200 and "errors" not in payload, payload
    rows = payload["data"]["movements"]
    assert [row["entry_source"] for row in rows].count("opening") == 1
    assert all(row["cutoff_id"] for row in rows)
    assert all(row["cargos"] <= 0 for row in rows)
    assert all(row["file_name"] for row in rows if row["entry_source"] == "upload")
    assert rows[-1]["balance"] == 472.2
