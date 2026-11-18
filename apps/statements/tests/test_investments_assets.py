"""sql/017: investment and asset accounts, master_closed_aaccandass_f, column maps,
manual rows, reconciliation and balances (Infonavit, CETES and GBM style data)."""

from __future__ import annotations

import json
import uuid
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest
from statements import graphql_api
from statements.rules import movement_row_hash_v2
from test_statement_flow import (
    DEBIT_CSV,
    _admin,
    _apply_all_ddl,
    _create,
    _ensure_login_role,
    _expect_error,
    _ingest,
    _json,
    _period,
    _session,
    _user,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"
INFONAVIT_CSV = (FIXTURES / "infonavit_aportaciones_anon.csv").read_text(encoding="utf-8")
INFONAVIT_MAP = {
    "txn_date": "Fecha de pago",
    "abono": "Aportación",
    "cargo": None,
    "concept": "Num. De Registro Patronal || ' - ' || Nombre de la empresa",
}


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
    return user_id, tenant_id


def _institution(conn, name):
    return conn.execute("SELECT bank_id FROM public.banks_d WHERE LOWER(bank_name) = LOWER(%s)", (name,)).fetchone()[0]


def _asset_account(conn, institution, name, number=None, type_name="Savings, investments, assets, credit contracts"):
    type_id = conn.execute(
        "SELECT a_type_id FROM public.account_types_d WHERE LOWER(type_name) = LOWER(%s)", (type_name,)
    ).fetchone()[0]
    return _one(
        conn,
        "SELECT public.create_asset_account(%s, NULL, %s, %s, %s)",
        (_institution(conn, institution), type_id, name, number),
    )["account_id"]


def _ingest_assets(conn, account_id, csv_text, mapping, name="file.csv", template=None):
    return _one(
        conn,
        "SELECT public.ingest_aaccandass_upload(%s, %s, %s, %s, %s::jsonb, %s, 'csv')",
        (account_id, name, name, csv_text, json.dumps(mapping), template),
    )


def _balance(conn, account_id, as_of):
    return Decimal(str(_one(conn, "SELECT public.aaccandass_balance(%s, %s)", (account_id, as_of))["balance"]))


def _add(conn, account_id, day, concept, abonos=0, cargos=0, note=None):
    return _one(
        conn,
        "SELECT public.add_aaccandass_row(%s, %s, %s, %s, %s, %s)",
        (account_id, day, concept, abonos, cargos, note),
    )


def _reconcile(conn, account_id, as_of, reported, adjust_date=None):
    return _one(
        conn,
        "SELECT public.reconcile_aaccandass(%s, %s, %s, %s, NULL, NULL)",
        (account_id, as_of, reported, adjust_date),
    )


# --- static pieces ---------------------------------------------------------------------


def test_seeds_types_institutions_and_plan_limit(conn):
    kinds = dict(
        conn.execute(
            "SELECT type_name, ledger_kind FROM public.account_types_d WHERE ledger_kind = 'asset'"
        ).fetchall()
    )
    assert kinds == {"Savings, investments, assets, credit contracts": "asset"}
    names = {
        row[0]
        for row in conn.execute("SELECT bank_name FROM public.banks_d WHERE is_institution").fetchall()
    }
    assert {"Infonavit", "Afore", "Cetesdirecto", "GBM", "Efectivo", "Bienes personales"} <= names
    limits = dict(conn.execute("SELECT plan_code, max_asset_accounts FROM public.plans_d").fetchall())
    assert limits["free"] == 2 and limits["premium"] == 20


def test_parse_date_and_concept_expression(conn):
    rows = conn.execute(
        """
        SELECT public.aaccandass_parse_date(v, f)
        FROM (VALUES ('14/09/2026', 'DMY'), ('2026-09-14', 'DMY'), ('09/14/2026', 'MDY'),
            ('46279', 'DMY'), ('14-sep-2026', 'DMY'), ('14.09.26', 'DMY'), ('2026-09-14 00:00:00', 'DMY'))
            AS t (v, f)
        """
    ).fetchall()
    assert {str(row[0]) for row in rows} == {"2026-09-14"}
    _expect_error(conn, "SELECT public.aaccandass_parse_date('31/02/2026')", (), "unreadable date", "22007")
    parts = _one(conn, "SELECT public.aaccandass_concept_parts(%s::jsonb)", (json.dumps(INFONAVIT_MAP["concept"]),))
    assert parts == [
        {"column": "Num. De Registro Patronal"},
        {"text": " - "},
        {"column": "Nombre de la empresa"},
    ]
    parts = _one(conn, """SELECT public.aaccandass_concept_parts('["A", "B"]'::jsonb, ' / ')""")
    assert parts == [{"column": "A"}, {"text": " / "}, {"column": "B"}]
    clean = _one(conn, """SELECT public.aaccandass_clean_mapping('{"txn_date": "F", "cargo": {"constant": 0}}')""")
    assert clean["cargo"] is None and clean["header_row"] == 1 and clean["date_format"] == "DMY"
    _expect_error(
        conn,
        """SELECT public.aaccandass_clean_mapping('{"cargo": {"constant": 5}}')""",
        (),
        "constant cargo can only be 0",
        "22023",
    )
    _expect_error(
        conn,
        """SELECT public.aaccandass_clean_mapping('{"amount": "X", "abono": "Y"}')""",
        (),
        "not both",
        "22023",
    )


def test_map_rows_signs_and_skips(conn):
    csv_text = (
        "Fecha,Detalle,Entrada,Salida\n"
        "01/10/2026,Deposito 1,100.50,\n"
        "02/10/2026,Retiro 2,,-40\n"
        "03/10/2026,Minusvalia,-12.5,\n"
        ",Sin fecha,5,\n"
        "xx/10/2026,Mala fecha,5,\n"
        "04/10/2026,Cero,0,0\n"
        "05/10/2026,,7,\n"
    )
    mapping = {"txn_date": "fecha", "abono": "ENTRADA", "cargo": "Salida", "concept": ["Detalle"]}
    rows = conn.execute(
        "SELECT line_no, txn_date::text, concept, abonos, cargos, status, reason "
        "FROM public.aaccandass_map_rows(%s, %s::jsonb) ORDER BY line_no",
        (csv_text, json.dumps(mapping)),
    ).fetchall()
    assert rows[0][2:6] == ("Deposito 1", Decimal("100.50"), Decimal("0.00"), "ok")
    assert rows[1][3:5] == (Decimal("0.00"), Decimal("40.00"))
    assert rows[2][3:5] == (Decimal("0.00"), Decimal("12.50"))
    assert rows[3][5:] == ("skipped", "no date")
    assert rows[4][5] == "skipped" and "unreadable date" in rows[4][6]
    assert rows[5][5:] == ("skipped", "amount is zero")
    assert rows[6][2] == "Movimiento"
    _expect_error(
        conn,
        "SELECT * FROM public.aaccandass_map_rows(%s, %s::jsonb)",
        (csv_text, json.dumps({"txn_date": "Fecha", "abono": "Nope"})),
        'Column "Nope" is not in the file',
    )


# --- Infonavit: upload with a column map, then reconcile ------------------------------


def test_infonavit_upload_template_and_reconcile(conn):
    user_id, _tenant_id = _owner(conn, "infonavit@example.com")
    account_id = _asset_account(conn, "Infonavit", "Subcuenta de vivienda")
    account = conn.execute(
        "SELECT account_number, bank_id FROM public.bank_accounts_d WHERE account_id = %s", (account_id,)
    ).fetchone()
    assert account[0].startswith("9") and len(account[0]) == 6

    blank = _one(conn, "SELECT public.aaccandass_preview(%s, %s, '{}'::jsonb)", (account_id, INFONAVIT_CSV))
    assert blank["ready"] is False
    assert "Fecha de pago" in blank["headers"]
    assert blank["suggested_mapping"]["txn_date"] == "Fecha de pago"
    assert blank["suggested_mapping"]["abono"] == "Aportación"

    preview = _one(
        conn, "SELECT public.aaccandass_preview(%s, %s, %s::jsonb)", (account_id, INFONAVIT_CSV, json.dumps(INFONAVIT_MAP))
    )
    assert preview["ready"] is True
    assert preview["totals"]["ok"] == 18 and preview["totals"]["new"] == 18
    assert Decimal(str(preview["totals"]["abonos"])) == Decimal("135661.56")
    assert Decimal(str(preview["balance_after"])) == Decimal("135661.56")
    assert preview["rows"][0]["concept"] == "Z1000000001 - EMPRESA A SA DE CV"
    assert conn.execute("SELECT COUNT(*) FROM public.master_closed_aaccandass_f").fetchone()[0] == 0

    result = _ingest_assets(conn, account_id, INFONAVIT_CSV, INFONAVIT_MAP, "infonavit.csv", "Infonavit SUA")
    assert result["inserted"] == 18 and result["duplicates"] == 0 and result["skipped"] == 0
    assert result["template_id"] is not None
    assert result["curated_csv_backup"] is False and result["vault_key"] is None
    assert _balance(conn, account_id, "2026-11-13") == Decimal("135661.56")

    # row_hash follows sql/014 with occurrence numbered in the file.
    row = conn.execute(
        "SELECT txn_date, concept_sk, abonos, cargos, occurrence, row_hash, period_start::text, entry_source "
        "FROM public.movement_keys_v WHERE source_table = 'master_closed_aaccandass_f' "
        "AND txn_date = '2026-09-14'"
    ).fetchone()
    assert row[1] == "1000000001" and row[6] == "2026-09-01" and row[7] == "upload"
    assert row[5] == movement_row_hash_v2(str(user_id), account_id, account[1], row[0], row[1], row[2], row[3], row[4])

    # Same bytes again: refused. An overlapping export: only new rows.
    _expect_error(
        conn,
        "SELECT public.ingest_aaccandass_upload(%s, 'x.csv', 'x.csv', %s, %s::jsonb, NULL, 'csv')",
        (account_id, INFONAVIT_CSV, json.dumps(INFONAVIT_MAP)),
        "already uploaded",
        "23505",
    )
    header, first, *_rest = INFONAVIT_CSV.splitlines()
    newer = header + "\n2026,Sep - Oct,Z1000000001,EMPRESA A SA DE CV,16/11/2026,9100.00,0.00\n" + first + "\n"
    again = _ingest_assets(conn, account_id, newer, INFONAVIT_MAP, "infonavit2.csv", "Infonavit SUA")
    assert again["inserted"] == 1 and again["duplicates"] == 1
    assert again["template_id"] == result["template_id"]

    home = _one(conn, "SELECT public.aaccandass_home('2026-11-20')")
    mine = next(item for item in home["accounts"] if item["account_id"] == account_id)
    assert len(mine["templates"]) == 1 and mine["templates"][0]["mapping"]["txn_date"] == "Fecha de pago"
    assert len(mine["uploads"]) == 2
    deleted = _one(conn, "SELECT public.delete_aaccandass_upload(%s)", (again["upload_id"],))
    assert deleted["deleted_rows"] == 1 and deleted["vault_delete_marker"] is None

    # The real balance: 438,225.05. The difference is one adjustment abono.
    check = _reconcile(conn, account_id, "2026-11-13", "438225.05")
    assert Decimal(str(check["tracked_balance"])) == Decimal("135661.56")
    assert Decimal(str(check["difference"])) == Decimal("302563.49")
    assert Decimal(str(check["adjustment"]["abonos"])) == Decimal("302563.49")
    assert check["adjustment"]["cargos"] == 0
    assert _balance(conn, account_id, "2026-11-13") == Decimal("438225.05")
    adjustment = conn.execute(
        "SELECT entry_source, concept, file_id FROM public.master_closed_aaccandass_f "
        "WHERE row_hash = %s",
        (check["adjustment"]["row_hash"],),
    ).fetchone()
    assert adjustment == ("adjustment", "Ajuste de saldo", None)
    # Typing the same balance again: nothing to adjust, the check is still kept.
    same = _reconcile(conn, account_id, "2026-11-13", "438225.05")
    assert Decimal(str(same["difference"])) == 0 and same["adjustment"] is None
    assert conn.execute(
        "SELECT COUNT(*) FROM public.aaccandass_checks_f WHERE account_id = %s", (account_id,)
    ).fetchone()[0] == 2
    # Uploaded rows are never edited and only leave with their file.
    _expect_error(
        conn,
        "UPDATE public.master_closed_aaccandass_f SET concept = 'x' WHERE account_id = %s",
        (account_id,),
        "",
    )
    upload_hash = conn.execute(
        "SELECT row_hash FROM public.master_closed_aaccandass_f WHERE entry_source = 'upload' LIMIT 1"
    ).fetchone()[0]
    _expect_error(conn, "SELECT public.delete_aaccandass_row(%s)", (upload_hash,), "deleting their file", "22023")


# --- CETES: manual rows from the PDF statements ----------------------------------------


def test_cetes_manual_rows_month_ends(conn):
    _owner(conn, "cetes@example.com")
    account_id = _asset_account(conn, "Cetesdirecto", "CETES")
    _add(conn, account_id, "2026-09-01", "Saldo inicial", abonos="395240.86")
    _add(conn, account_id, "2026-09-30", "Rendimiento septiembre", abonos="1922.17")
    assert _balance(conn, account_id, "2026-09-30") == Decimal("397163.03")
    _add(conn, account_id, "2026-10-13", "EGREFVO", cargos="188000")
    _add(conn, account_id, "2026-10-31", "Rendimiento octubre", abonos="1650.65")
    assert _balance(conn, account_id, "2026-10-31") == Decimal("210813.68")
    assert _balance(conn, account_id, "2026-10-12") == Decimal("397163.03")

    for as_of, reported in (("2026-09-30", "397163.03"), ("2026-10-31", "210813.68")):
        check = _reconcile(conn, account_id, as_of, reported)
        assert Decimal(str(check["difference"])) == 0 and check["adjustment"] is None

    months = _one(conn, "SELECT public.aaccandass_balances('2026-10-31', 3)")
    cetes = next(item for item in months["accounts"] if item["account_id"] == account_id)
    by_month = {item["month"]: item for item in cetes["months"]}
    assert Decimal(str(by_month["2026-08"]["balance"])) == 0
    assert Decimal(str(by_month["2026-09"]["balance"])) == Decimal("397163.03")
    assert Decimal(str(by_month["2026-09"]["abonos"])) == Decimal("397163.03")
    assert Decimal(str(by_month["2026-10"]["cargos"])) == Decimal("188000.00")
    assert Decimal(str(by_month["2026-10"]["balance"])) == Decimal("210813.68")

    rows = _one(conn, "SELECT public.aaccandass_rows(%s)", (account_id,))
    assert rows["total"] == 4
    assert Decimal(str(rows["rows"][0]["balance"])) == Decimal("210813.68")
    assert rows["rows"][0]["entry_source"] == "manual"

    # Wrong inputs are refused; a manual row can be deleted.
    _expect_error(
        conn, "SELECT public.add_aaccandass_row(%s, '2026-10-01', 'x', -5, 0, NULL)", (account_id,), "positive", "22023"
    )
    _expect_error(
        conn, "SELECT public.add_aaccandass_row(%s, '2026-10-01', 'x', 0, 0, NULL)", (account_id,), "abono or a cargo"
    )
    extra = _add(conn, account_id, "2026-10-31", "Rendimiento octubre", abonos="1650.65")
    assert extra["row_hash"] != rows["rows"][0]["row_hash"]
    _one(conn, "SELECT public.delete_aaccandass_row(%s)", (extra["row_hash"],))
    assert _balance(conn, account_id, "2026-10-31") == Decimal("210813.68")


# --- GBM: a snapshot only, so reconcile creates the opening row ------------------------


def test_gbm_snapshot_becomes_opening_row(conn):
    _owner(conn, "gbm@example.com")
    account_id = _asset_account(conn, "GBM", "GBM portafolio")
    check = _reconcile(conn, account_id, "2026-11-12", "14467.34", "2026-11-01")
    assert Decimal(str(check["adjustment"]["abonos"])) == Decimal("14467.34")
    assert check["adjustment"]["txn_date"] == "2026-11-01"
    assert _balance(conn, account_id, "2026-11-12") == Decimal("14467.34")
    assert _balance(conn, account_id, "2026-10-31") == 0
    loss = _reconcile(conn, account_id, "2026-11-30", "14000")
    assert Decimal(str(loss["adjustment"]["cargos"])) == Decimal("467.34")
    _expect_error(
        conn,
        "SELECT public.reconcile_aaccandass(%s, '2026-11-01', 1, '2026-11-02', NULL, NULL)",
        (account_id,),
        "on or before",
        "22023",
    )


# --- accounts, plan limits, statements page ---------------------------------------------


def test_asset_accounts_have_own_limit_and_skip_statements(conn):
    _owner(conn, "limits@example.com")
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    first = _asset_account(conn, "Infonavit", "Infonavit")
    second = _one(
        conn,
        "SELECT public.create_asset_account(NULL, 'Mi Casa Propia', "
        "(SELECT a_type_id FROM public.account_types_d WHERE type_name = 'Savings, investments, assets, credit contracts'), 'Casa', '700001')",
    )
    assert second["bank_name"] == "Mi Casa Propia" and second["type_name"] == "Savings, investments, assets, credit contracts"
    _expect_error(
        conn,
        "SELECT public.create_asset_account(%s, NULL, NULL, 'Afore', NULL)",
        (_institution(conn, "Afore"),),
        "at most 2 investment or asset",
        "23514",
    )
    home = _one(conn, "SELECT public.statement_home('2026-11-13')")
    assert [item["account_id"] for item in home["accounts"]][0] == debit_id
    assets = [item for item in home["accounts"] if item["ledger_kind"] == "asset"]
    assert {item["account_id"] for item in assets} == {first, second["account_id"]}
    assert all(item["upload_cutoff_id"] and item["periods"] == [] for item in assets)
    assert {kind["type_name"] for kind in home["account_types"]} == {
        "Bank credit card", "Bank debit", "Savings, investments, assets, credit contracts",
    }
    assert "Infonavit" in {bank["bank_name"] for bank in home["banks"]}
    completeness = _one(conn, "SELECT public.upload_completeness('2026-11-13')")
    listed = {
        account["account_id"]
        for kind in completeness["kinds"]
        for bank in kind["banks"]
        for account in bank["accounts"]
    }
    assert listed == {debit_id} and first not in listed
    _expect_error(
        conn,
        "SELECT public.aaccandass_balance(%s, NULL)",
        (debit_id,),
        "investment or asset account not found",
        "P0002",
    )


# --- dimensions, lists, GraphQL ----------------------------------------------------------


def test_dimensions_lists_and_graphql_on_asset_rows(conn):
    _owner(conn, "assetdims@example.com")
    debit_id = _create(conn, "bank debit", "Debit", "0639")
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-09")["cutoff_id"], "statement", "0639.csv", DEBIT_CSV)
    account_id = _asset_account(conn, "Cetesdirecto", "CETES")
    row = _add(conn, account_id, "2026-09-30", "Rendimiento", abonos="1922.17")
    assert conn.execute(
        "SELECT COUNT(*) FROM public.master_closed_aaccandass_d WHERE row_hash = %s", (row["row_hash"],)
    ).fetchone()[0] == 1

    summary = _one(conn, "SELECT public.dimension_summary()")
    assert summary["asset"]["total"] == 1 and summary["asset"]["layers"]["closed"]["total"] == 1
    assert summary["debit"]["total"] == 3

    saved = _one(conn, "SELECT public.save_dimension_values(%s, %s::jsonb)", (row["row_hash"], '{"attribute_1": "Ahorro"}'))
    assert saved["kind"] == "asset" and saved["attribute_1"] == "Ahorro"
    lst = _one(conn, "SELECT public.create_list('Categorias')")
    bound = _one(conn, "SELECT public.set_attribute_setting(1, 'Categoria', %s)", (lst["list_id"],))
    assert bound["converted"] == 1
    item_id = conn.execute(
        "SELECT attribute_1_item_id FROM public.master_closed_aaccandass_d WHERE row_hash = %s", (row["row_hash"],)
    ).fetchone()[0]
    assert item_id is not None
    catalog = _one(conn, "SELECT public.list_catalog()")
    items = catalog["lists"][0]["items"]
    assert any(item["item_name"] == "Ahorro" and item["used"] >= 1 for item in items)

    rows = _one(conn, "SELECT public.dimension_rows('asset', 'closed')")
    assert rows["total"] == 1 and rows["rows"][0]["attribute_1"] == "Ahorro"
    assert rows["rows"][0]["source_profile"] == "manual"
    assert Decimal(str(rows["rows"][0]["balance"])) == Decimal("1922.17")
    opened = _one(conn, "SELECT public.dimension_rows('asset', 'open')")
    assert opened["total"] == 0

    data = _one(conn, "SELECT public.graphql_rows('master_closed_aaccandass_f', NULL, NULL, '2026-11-13')")
    assert len(data) == 1 and data[0]["kind"] == "asset" and data[0]["attribute_1"] == "Ahorro"
    assert data[0]["is_internal_transfer"] is False
    debit_rows = _one(conn, "SELECT public.graphql_rows('master_debit_closed_f', NULL, NULL, '2026-11-13')")
    # sql/018: every account kind carries a running balance.
    assert all(item["balance"] is not None for item in debit_rows)
    # Asset rows never enter transfer detection.
    pool = conn.execute(
        "SELECT COUNT(*) FROM public.transfer_pool(public.session_tenant(), public.session_user()) WHERE kind = 'asset'"
    ).fetchone()[0]
    assert pool == 0


def test_graphql_schema_has_asset_table():
    sdl = graphql_api.SDL
    assert "ASSET" in sdl and "balance: Float" in sdl and "source_profile: String" in sdl
    assert graphql_api.TABLES[("ASSET", "CLOSED")] == "master_closed_aaccandass_f"
    assert graphql_api.TABLES[("ASSET", "OPEN")] == "master_open_aaccandass_f"


# --- isolation, vault, privacy ------------------------------------------------------------


def test_other_users_cannot_touch_asset_accounts(conn):
    _owner(conn, "owner-a@example.com")
    account_id = _asset_account(conn, "GBM", "GBM")
    row = _add(conn, account_id, "2026-11-01", "Saldo", abonos="10")
    _owner(conn, "owner-b@example.com")
    for sql, params in (
        ("SELECT public.add_aaccandass_row(%s, '2026-11-02', 'x', 1, 0, NULL)", (account_id,)),
        ("SELECT public.reconcile_aaccandass(%s, '2026-11-02', 1, NULL, NULL, NULL)", (account_id,)),
        ("SELECT public.aaccandass_rows(%s)", (account_id,)),
        ("SELECT public.delete_aaccandass_row(%s)", (row["row_hash"],)),
    ):
        _expect_error(conn, sql, params, "not found", "P0002")
    assert _one(conn, "SELECT public.aaccandass_home(NULL)")["accounts"] == []


def test_vault_name_and_manifest_when_plan_keeps_backups(conn):
    _, tenant_id = _owner(conn, "vault-assets@example.com")
    conn.execute(
        "UPDATE public.tenants_d SET plan_code = (SELECT plan_code FROM public.plans_d "
        "WHERE curated_csv_backup ORDER BY plan_code LIMIT 1) WHERE tenant_id = %s",
        (tenant_id,),
    )
    account_id = _asset_account(conn, "Infonavit", "Infonavit", "900123")
    result = _ingest_assets(conn, account_id, INFONAVIT_CSV, INFONAVIT_MAP, "Mis aportaciones.xlsx")
    assert result["curated_csv_backup"] is True
    assert result["vault_key"] == f"curated/{tenant_id}/2026-09_900123_Infonavit_inv.csv"
    assert result["vault_manifest_key"] == f"curated/{tenant_id}/manifest/2026-09_900123_Infonavit_inv.csv.json"
    manifest = result["vault_manifest"]
    assert manifest["dataset"] == "aaccandass" and manifest["table"] == "master_closed_aaccandass_f"
    assert manifest["mapping"]["txn_date"] == "Fecha de pago" and manifest["row_count"] == 18
    assert result["vault_metadata"]["period"] == "2026-09"
    _expect_error(
        conn, "SELECT public.attach_aaccandass_backup(%s, 'curated/x/y.csv')", (result["upload_id"],), "does not match"
    )
    conn.execute("SELECT public.attach_aaccandass_backup(%s, %s)", (result["upload_id"], result["vault_key"]))
    deleted = _one(conn, "SELECT public.delete_aaccandass_upload(%s)", (result["upload_id"],))
    assert deleted["vault_delete_marker"]["key"].endswith("2026-09_900123_Infonavit_inv.csv.deleted.json")


def test_fixture_is_anonymized():
    text = INFONAVIT_CSV
    assert "EMPRESA A SA DE CV" in text
    assert "CONSULTING" not in text.upper()
    for line in text.splitlines()[1:]:
        assert line.split(",")[2].startswith("Z1")


# --- the API routes as the app role, Sheets and the browser converter --------------------


def test_local_api_routes_as_app_role(conn):
    from statements.local_api import dispatch_017

    _owner(conn, "routes-assets@example.com")
    conn.execute("SET LOCAL ROLE strm_app")
    with conn.cursor() as cur:

        def route(method, path, body=None, **params):
            return dispatch_017(cur, method, path, {key: [str(value)] for key, value in params.items()}, lambda: body or {})

        institutions = route("GET", "/assets")[1]["institutions"]
        infonavit = next(item["bank_id"] for item in institutions if item["bank_name"] == "Infonavit")
        status, created = route("POST", "/assets/accounts", {"bank_id": infonavit, "account_name": "Vivienda"})
        assert status == 200
        account_id = created["account_id"]
        status, preview = route(
            "POST", "/assets/preview", {"account_id": account_id, "csv": INFONAVIT_CSV, "mapping": INFONAVIT_MAP}
        )
        assert preview["totals"]["new"] == 18
        status, saved = route(
            "POST",
            "/assets/uploads",
            {"account_id": account_id, "filename": "i.csv", "csv": INFONAVIT_CSV, "mapping": INFONAVIT_MAP,
             "template_name": "SUA"},
        )
        assert saved["inserted"] == 18 and "vault_manifest" not in saved and "vault_key" not in saved
        status, check = route(
            "POST", "/assets/reconcile", {"account_id": account_id, "as_of": "2026-11-13", "reported_balance": "438,225.05"}
        )
        assert Decimal(str(check["difference"])) == Decimal("302563.49")
        assert route("POST", "/assets/reconcile", {"account_id": account_id, "as_of": "2026-11-13",
                                                   "reported_balance": "abc"})[0] == 400
        status, row = route(
            "POST", "/assets/rows", {"account_id": account_id, "txn_date": "2026-11-14", "concept": "Extra", "abonos": "10"}
        )
        rows = route("GET", "/assets/rows", account_id=account_id)[1]
        assert rows["total"] == 20 and Decimal(str(rows["rows"][0]["balance"])) == Decimal("438235.05")
        assert route("DELETE", f"/assets/rows/{row['row_hash']}")[1]["deleted"] is True
        assert route("DELETE", "/assets/rows/nothex")[0] == 400
        balances = route("GET", "/assets/balances", as_of="2026-11-30", months=3)[1]
        assert Decimal(str(balances["total"][-1]["balance"])) == Decimal("438225.05")
        template_id = route("GET", "/assets")[1]["accounts"][0]["templates"][0]["template_id"]
        assert route("DELETE", f"/assets/templates/{template_id}")[1]["deleted"] is True
        assert route("GET", "/statements") is None
        # The app role reads the tables through RLS, never the file body.
        assert cur.execute("SELECT COUNT(*) FROM public.master_closed_aaccandass_f").fetchone()[0] == 19
        cur.execute("SAVEPOINT body")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            cur.execute("SELECT body_text FROM public.aaccandass_uploads_f")
        cur.execute("ROLLBACK TO SAVEPOINT body")


def test_sheets_default_tabs_return_asset_rows(conn, database_url):
    from test_dimensions_graphql import _token
    from test_graphql_node import NODE, _apps_script

    if NODE is None:
        pytest.skip("node not installed")
    _owner(conn, "sheets-assets@example.com")
    conn.execute("UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = public.session_tenant()")
    account_id = _asset_account(conn, "Cetesdirecto", "CETES")
    _add(conn, account_id, "2026-09-01", "Saldo inicial", abonos="395240.86")
    _add(conn, account_id, "2026-09-30", "Rendimiento", abonos="1922.17")
    token = _token(conn)["token"]
    conn.commit()
    built = _apps_script({}, 200, "console.log(JSON.stringify(vm.runInContext('buildQuery(DEFAULT_TABS)', context)));")
    body = json.dumps({"query": built["query"], "operationName": "RefreshAll"})
    with psycopg.connect(database_url) as db:
        status, payload, _ = graphql_api.handle(db, f"Bearer {token}", body)
    assert status == 200 and "errors" not in payload, payload
    assets = payload["data"]["t5"]
    assert [row["balance"] for row in assets] == [395240.86, 397163.03]
    assert assets[0]["source_profile"] == "manual"
    assert set(assets[0]) == set(built["plan"][5]["columns"])


def test_browser_converter_reads_any_xlsx_with_dates():
    from test_graphql_node import NODE

    if NODE is None:
        pytest.skip("node not installed")
    import subprocess

    js = Path(__file__).resolve().parents[3] / "web" / "xlsx_to_csv.js"
    xlsx = FIXTURES / "infonavit_aportaciones_anon.xlsx"
    script = f"""
const fs = require('fs');
eval(fs.readFileSync({str(js)!r}, 'utf8'));
(async () => {{
  const b = fs.readFileSync({str(xlsx)!r});
  const buf = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  const first = await strmXlsxToRows(buf);
  const notes = await strmXlsxToRows(buf, {{ sheet: 'Notas' }});
  console.log(JSON.stringify({{ first, notes }}));
}})().catch((e) => {{ console.error(e); process.exit(1); }});
"""
    done = subprocess.run([NODE, "-e", script], check=False, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    out = json.loads(done.stdout)
    assert out["first"]["sheets"] == ["Sheet1", "Notas"]
    assert out["first"]["rows"][0][4] == "Fecha de pago"
    assert out["first"]["rows"][1][4:6] == ["2026-09-14", "9064.95"]
    assert out["first"]["csv"].splitlines()[1].startswith("2026,Jul - Ago,Z1000000001,EMPRESA A SA DE CV,2026-09-14")
    assert out["notes"]["rows"] == [["Saldo", "1234.5"]]


def test_account_types_route_the_open_and_closed_asset_tables(conn):
    families = {
        row[0]: (row[1], row[2])
        for row in conn.execute(
            "SELECT type_name, public.account_type_family(type_name), ledger_kind "
            "FROM public.account_types_d ORDER BY type_name"
        ).fetchall()
    }
    assert set(families) == {
        "Bank credit card", "Bank debit", "Savings, investments, assets, credit contracts",
    }
    assert families["Bank credit card"] == ("credit", "credit")
    assert families["Bank debit"] == ("debit", "debit")
    assert families["Savings, investments, assets, credit contracts"] == ("asset", "asset")

    _owner(conn, "types-open@example.com")
    account_id = _asset_account(conn, "Cetesdirecto", "Ahorro", "816090")
    today, earlier = conn.execute(
        """
        SELECT (NOW() AT TIME ZONE 'America/Mexico_City')::DATE,
               ((NOW() AT TIME ZONE 'America/Mexico_City')::DATE - INTERVAL '40 days')::DATE
        """
    ).fetchone()
    mapping = {"txn_date": "Fecha", "concept": "Concepto", "amount": "Importe"}
    csv_text = (
        "Fecha,Concepto,Importe\n"
        f"{earlier.strftime('%d/%m/%Y')},Mes pasado,-10\n"
        f"{today.strftime('%d/%m/%Y')},Mes actual,-20\n"
    )
    preview = _one(
        conn, "SELECT public.column_map_preview(%s, %s, %s::jsonb)", (account_id, csv_text, json.dumps(mapping))
    )
    assert preview["kind"] == "asset" and preview["cargo_sign"] == "positive"
    assert [Decimal(str(row["cargos"])) for row in preview["rows"] if row["status"] == "ok"] == [
        Decimal("10.00"), Decimal("20.00"),
    ]
    loaded = _ingest_assets(conn, account_id, csv_text, mapping, "ahorro.csv")
    assert loaded["open_inserted"] == 1 and loaded["closed_inserted"] == 1
    assert loaded["target_table"] == "master_open_aaccandass_f, master_closed_aaccandass_f"
    assert conn.execute(
        "SELECT cargos FROM public.master_closed_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchone()[0] == Decimal("10.00")
    assert conn.execute(
        "SELECT cargos FROM public.master_open_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchone()[0] == Decimal("20.00")
    opened = _one(conn, "SELECT public.graphql_rows('master_open_aaccandass_f', NULL, NULL, NULL)")
    assert len(opened) == 1 and opened[0]["layer"] == "open" and opened[0]["kind"] == "asset"

    replaced = _ingest_assets(
        conn, account_id,
        "Fecha,Concepto,Importe\n" + f"{today.strftime('%d/%m/%Y')},Mes actual reemplazo,-30\n",
        mapping, "ahorro-2.csv",
    )
    assert replaced["open_inserted"] == 1 and replaced["closed_inserted"] == 0
    assert conn.execute(
        "SELECT concept, cargos FROM public.master_open_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchone() == ("Mes actual reemplazo", Decimal("30.00"))
    assert conn.execute(
        "SELECT COUNT(*) FROM public.master_closed_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchone()[0] == 1
    home = _one(conn, "SELECT public.statement_home(%s)", (today,))
    card = next(item for item in home["accounts"] if item["account_id"] == account_id)
    assert card["open_row_count"] == 1 and card["closed_row_count"] == 1
    assert {upload["filename"] for upload in card["uploads"]} == {"ahorro.csv", "ahorro-2.csv"}


def test_statements_page_uploads_and_cleans_asset_accounts(conn):
    user_id, tenant_id = _owner(conn, "cetes-page@example.com")
    legacy = _create(conn, "bank debit", "Legacy", "0640")
    _ingest(conn, legacy, _period(conn, legacy, "2026-09")["cutoff_id"], "statement", "0640.csv", DEBIT_CSV)
    _one(conn, "SELECT public.add_opening_balance(%s, 100, '2025-01-01')", (legacy,))
    conn.execute(
        "UPDATE public.bank_accounts_d SET a_type_id = (SELECT a_type_id FROM public.account_types_d "
        "WHERE type_name = 'Savings, investments, assets, credit contracts') WHERE account_id = %s",
        (legacy,),
    )
    conn.execute((Path(__file__).resolve().parents[3] / "sql" / "020_statement_home_asset_accounts.sql").read_text())
    _session(conn, user_id, tenant_id)
    assert conn.execute(
        "SELECT COUNT(*) FROM public.movement_keys_v WHERE account_id = %s", (legacy,)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT COUNT(*) FROM public.statement_uploads_f WHERE account_id = %s", (legacy,)
    ).fetchone()[0] == 0

    account_id = _asset_account(conn, "Cetesdirecto", "CETES", "816089")
    home = _one(conn, "SELECT public.statement_home('2026-11-14')")
    card = next(item for item in home["accounts"] if item["account_id"] == account_id)
    csv_text = (
        "txn_date,concept,abono,cargo\n"
        "30/09/26,Rendimiento / valuación del periodo,1922.17,0\n"
        "13/10/26,EGREFVO retiro a cuenta bancaria,0,188000\n"
        "31/10/26,Rendimiento / valuación del periodo,1650.65,0\n"
    )
    mapping = {"txn_date": "txn_date", "concept": "concept", "abono": "abono", "cargo": "cargo"}
    _expect_error(
        conn,
        "SELECT public.ingest_statement_upload(%s, %s, 'statement', 'c.csv', 'c.csv', %s, '2026-11-14')",
        (account_id, card["upload_cutoff_id"], csv_text),
        "map the columns",
        "22P02",
    )
    loaded = _one(
        conn,
        "SELECT public.ingest_statement_upload(%s, %s, 'statement', 'c.csv', 'cetes.csv', %s, '2026-11-14', "
        "NULL, NULL, %s::jsonb, NULL)",
        (account_id, card["upload_cutoff_id"], csv_text, json.dumps(mapping)),
    )
    assert loaded["inserted"] == 3 and loaded["target_table"] == "master_closed_aaccandass_f"
    assert "vault_key" not in loaded
    assert conn.execute(
        "SELECT SUM(cargos) FROM public.master_closed_aaccandass_f WHERE account_id = %s", (account_id,)
    ).fetchone()[0] == Decimal("188000.00")

    wizard_map = {**mapping, "header_row": 1, "date_format": "DMY"}
    direct = _ingest_assets(conn, legacy, csv_text, wizard_map, "cetes.csv")
    assert direct["inserted"] == 3 and direct["vault_key"] is None


def test_delete_account_drops_its_files_then_bank_can_go(conn):
    _owner(conn, "delete-account@example.com")
    debit_id = _create(conn, "bank debit", "Payroll", "0641")
    _ingest(conn, debit_id, _period(conn, debit_id, "2026-09")["cutoff_id"], "statement", "0641.csv", DEBIT_CSV)
    _one(conn, "SELECT public.add_opening_balance(%s, 100, '2025-01-01')", (debit_id,))
    bank = _one(conn, "SELECT public.create_bank('Banco Para Borrar', TRUE)")
    asset_type = conn.execute(
        "SELECT a_type_id FROM public.account_types_d WHERE type_name = 'Savings, investments, assets, credit contracts'"
    ).fetchone()[0]
    asset_id = _one(
        conn, "SELECT public.create_asset_account(%s, NULL, %s, 'Ahorro', '9001')", (bank["bank_id"], asset_type)
    )["account_id"]
    _ingest_assets(
        conn, asset_id, "Fecha,Concepto,Importe\n01/09/2026,Aporte,500\n",
        {"txn_date": "Fecha", "concept": "Concepto", "amount": "Importe"}, "ahorro.csv",
    )
    _expect_error(
        conn, "SELECT public.delete_bank(%s)", (bank["bank_id"],), "Move or delete its accounts first", "42501"
    )

    deleted = _one(conn, "SELECT public.delete_bank_account(%s)", (debit_id,))
    assert deleted["deleted_files"] == 1
    gone_asset = _one(conn, "SELECT public.delete_bank_account(%s)", (asset_id,))
    assert gone_asset["deleted_files"] == 1
    for account_id in (debit_id, asset_id):
        assert conn.execute(
            "SELECT COUNT(*) FROM public.movement_keys_v WHERE account_id = %s", (account_id,)
        ).fetchone()[0] == 0
        assert conn.execute(
            "SELECT COUNT(*) FROM public.bank_accounts_d WHERE account_id = %s", (account_id,)
        ).fetchone()[0] == 0
    assert _one(conn, "SELECT public.delete_bank(%s)", (bank["bank_id"],))["bank_name"] == "Banco Para Borrar"
    _expect_error(conn, "SELECT public.delete_bank_account(%s)", (debit_id,), "account not found", "P0002")


SQL_022 = Path(__file__).resolve().parents[3] / "sql" / "022_starter_banks.sql"


def test_starter_banks_stay_and_user_banks_can_go(conn):
    user_id, tenant_id = _owner(conn, "starter-banks@example.com")
    conn.execute(SQL_022.read_text())
    _session(conn, user_id, tenant_id)

    shared = {
        row[0]
        for row in conn.execute(
            "SELECT LOWER(bank.bank_name) FROM public.banks_d AS bank WHERE bank.created_by IS NULL "
            "AND NOT EXISTS (SELECT 1 FROM public.bank_accounts_d AS account WHERE account.bank_id = bank.bank_id)"
        )
    }
    assert shared <= {"banorte", "bbva", "hsbc"}

    catalog = {bank["bank_name"].lower(): bank for bank in _one(conn, "SELECT public.bank_catalog()")}
    assert catalog["banorte"]["can_remove"] is False
    assert catalog["banorte"]["remove_block"] == "Starter bank; it cannot be removed"
    _expect_error(
        conn, "SELECT public.delete_bank(%s)", (catalog["banorte"]["bank_id"],),
        "Only a bank you added can be removed", "42501",
    )

    asset_type = conn.execute(
        "SELECT a_type_id FROM public.account_types_d WHERE type_name = 'Savings, investments, assets, credit contracts'"
    ).fetchone()[0]
    account = _one(conn, "SELECT public.create_asset_account(NULL, 'Mi Afore', %s, 'Retiro', NULL)", (asset_type,))
    bank_id = conn.execute(
        "SELECT bank_id FROM public.bank_accounts_d WHERE account_id = %s", (account["account_id"],)
    ).fetchone()[0]
    catalog = {bank["bank_id"]: bank for bank in _one(conn, "SELECT public.bank_catalog()")}
    assert catalog[bank_id]["remove_block"] == "Move or delete its accounts first"

    _one(conn, "SELECT public.delete_bank_account(%s)", (account["account_id"],))
    catalog = {bank["bank_id"]: bank for bank in _one(conn, "SELECT public.bank_catalog()")}
    assert catalog[bank_id]["can_remove"] is True
    assert _one(conn, "SELECT public.delete_bank(%s)", (bank_id,))["bank_name"] == "Mi Afore"


SQL_023 = Path(__file__).resolve().parents[3] / "sql" / "023_asset_periods.sql"


def test_asset_accounts_list_periods_like_debit(conn):
    user_id, tenant_id = _owner(conn, "asset-periods@example.com")
    conn.execute(SQL_023.read_text())
    _session(conn, user_id, tenant_id)
    account_id = _asset_account(conn, "Cetesdirecto", "CETES", "816077")

    def card():
        home = _one(conn, "SELECT public.statement_home('2026-11-14')")
        return next(item for item in home["accounts"] if item["account_id"] == account_id)

    periods = card()["periods"]
    assert [p["period_label"] for p in periods][-1] == "2026-11"
    assert len(periods) >= 3 and periods[-1]["is_current"] is True

    upload = _ingest_assets(
        conn, account_id, "Fecha,Concepto,Importe\n30/09/2026,Rend,10\n31/10/2026,Rend,20\n",
        {"txn_date": "Fecha", "concept": "Concepto", "amount": "Importe", "date_format": "DMY"}, "cetes.csv",
    )
    by_label = {p["period_label"]: p for p in card()["periods"]}
    assert [f["upload_id"] for f in by_label["2026-10"]["files"]] == [upload["upload_id"]]
    assert by_label["2026-10"]["pending"] is False and by_label["2026-09"]["files"] == []

    oldest = min(p["period_end"] for p in card()["periods"])
    conn.execute("SELECT public.add_earlier_period(%s, '2026-11-14')", (account_id,))
    added = min(card()["periods"], key=lambda p: p["period_end"])
    assert added["period_end"] < oldest and added["removable"] is True

    october = by_label["2026-10"]["cutoff_id"]
    _expect_error(
        conn, "SELECT public.remove_statement_period(%s, '2027-06-01')", (october,),
        "Delete the uploaded file before removing the period", "23503",
    )
    conn.execute("SELECT public.remove_statement_period(%s, '2026-11-14')", (added["cutoff_id"],))
    assert all(p["cutoff_id"] != added["cutoff_id"] for p in card()["periods"])


MASTER_FACT_TABLES = (
    "master_credit_closed_f",
    "master_credit_open_f",
    "master_credit_future_f",
    "master_debit_closed_f",
    "master_debit_open_f",
    "master_closed_aaccandass_f",
    "master_open_aaccandass_f",
)
MASTER_DIMENSION_TABLES = ("debit_d", "credit_d", "master_closed_aaccandass_d")


def _columns(conn, table):
    return [
        (name, kind)
        for name, kind in conn.execute(
            "SELECT attribute.attname, FORMAT_TYPE(attribute.atttypid, attribute.atttypmod) "
            "FROM pg_attribute AS attribute WHERE attribute.attrelid = ('public.' || %s)::REGCLASS "
            "AND attribute.attnum > 0 AND NOT attribute.attisdropped ORDER BY attribute.attnum",
            (table,),
        )
    ]


@pytest.mark.parametrize("tables", [MASTER_FACT_TABLES, MASTER_DIMENSION_TABLES], ids=["facts", "dimensions"])
def test_master_tables_share_the_same_columns(conn, tables):
    reference = _columns(conn, tables[0])
    differences = {}
    for table in tables[1:]:
        columns = _columns(conn, table)
        if set(columns) != set(reference):
            differences[table] = {
                "extra": sorted(set(columns) - set(reference)),
                "missing": sorted(set(reference) - set(columns)),
            }
        elif columns != reference:
            differences[table] = {"order": [name for name, _ in columns]}
    assert not differences, f"columns differ from {tables[0]}: {differences}"
