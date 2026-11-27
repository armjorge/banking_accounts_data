"""sql/016: attribute lists, transfer links between accounts, upload completeness."""

from __future__ import annotations

import json
import uuid

import psycopg
import pytest
from statements import graphql_api
from test_statement_flow import (
    DEBIT_CSV,
    MSI_AS_OF,
    _admin,
    _apply_all_ddl,
    _create,
    _current,
    _ensure_login_role,
    _expect_error,
    _ingest,
    _json,
    _period,
    _session,
    _upload_pdf,
    _user,
)

A_OPEN = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "03/11/2026,SPEI ENVIADO 4411,-250.0,0.0,750.0\n"
    "05/11/2026,PAGO TARJETA 3978,-500.0,0.0,250.0\n"
    "06/11/2026,SPEI ENVIADO 9001,-300.0,0.0,-50.0\n"
    "07/11/2026,COMISION 77,-5.0,0.0,-55.0\n"
)
B_OPEN = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "03/11/2026,SPEI RECIBIDO 4411,0.0,250.0,1250.0\n"
    "08/11/2026,DEPOSITO 55,0.0,5.0,1255.0\n"
)
D_OPEN = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "06/11/2026,SPEI RECIBIDO 9001,0.0,300.0,300.0\n"
)
SEP_CSV = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n15/09/2026,SPEI ENVIADO 1,-10.0,0.0,90.0\n"
)
C_OPEN = (
    "Fecha,Concepto,Abono,Cargo,Tarjeta\r\n"
    "05/11/2026,PAGO 456 Referencia ,500.00,0,Titular ***3978\r\n"
    "08/11/2026,OXXO 123 Referencia ,0,85.50,Titular ***3978\r\n"
)


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


def _open_slot(conn, account_id):
    return _current(conn, account_id, MSI_AS_OF)["cutoff_id"]


def _seed_lists(conn, email):
    user_id, tenant_id = _user(conn, email)
    _session(conn, user_id, tenant_id)
    conn.execute(
        "UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s",
        (tenant_id,),
    )
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(
        conn,
        debit_id,
        _open_slot(conn, debit_id),
        "statement",
        "a.csv",
        A_OPEN,
        MSI_AS_OF,
    )
    rows = conn.execute(
        "SELECT row_hash, concept FROM public.master_debit_open_f WHERE account_id = %s ORDER BY txn_date, row_id",
        (debit_id,),
    ).fetchall()
    return user_id, tenant_id, debit_id, [row[0] for row in rows]


def _bank_id(conn, name):
    return conn.execute(
        "SELECT bank_id FROM public.banks_d WHERE LOWER(bank_name) = LOWER(%s)", (name,)
    ).fetchone()[0]


def _seed_transfers(conn, email):
    """Debit A sends to debit B (same bank), to card C (payment) and to debit D (other bank)."""
    user_id, tenant_id = _user(conn, email)
    _session(conn, user_id, tenant_id)
    conn.execute(
        "UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s",
        (tenant_id,),
    )
    a_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    b_id = _create(conn, "bank debit", "Savings", "1122", as_of=MSI_AS_OF)
    d_id = _create(conn, "bank debit", "Other bank", "7788", as_of=MSI_AS_OF)
    c_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    _ingest(conn, d_id, _open_slot(conn, d_id), "statement", "d.csv", D_OPEN, MSI_AS_OF)
    # D belongs to another bank (the Banorte CSV profile is only used to load it).
    other = _bank_id(conn, "BBVA")
    conn.execute(
        "UPDATE public.bank_accounts_d SET bank_id = %s WHERE account_id = %s",
        (other, d_id),
    )
    conn.execute(
        "UPDATE public.master_debit_open_f SET bank_id = %s WHERE account_id = %s",
        (other, d_id),
    )
    _ingest(conn, b_id, _open_slot(conn, b_id), "statement", "b.csv", B_OPEN, MSI_AS_OF)
    _ingest(conn, c_id, _open_slot(conn, c_id), "statement", "c.csv", C_OPEN, MSI_AS_OF)
    _ingest(conn, a_id, _open_slot(conn, a_id), "statement", "a.csv", A_OPEN, MSI_AS_OF)
    return user_id, tenant_id, {"A": a_id, "B": b_id, "C": c_id, "D": d_id}


def _hash(conn, account_id, concept_like):
    return conn.execute(
        """
        SELECT row_hash FROM public.movement_keys_v
        WHERE account_id = %s AND concept LIKE %s ORDER BY layer LIMIT 1
        """,
        (account_id, concept_like),
    ).fetchone()[0]


def _links(conn):
    return _one(conn, "SELECT public.transfer_links()")


# --- lists -------------------------------------------------------------------------------


def test_lists_items_and_rename_propagates_to_rows_and_graphql(conn, database_url):
    _user_id, _tenant_id, _debit_id, hashes = _seed_lists(conn, "lists@example.com")
    food = _one(conn, "SELECT public.create_list(%s)", ("  Categories ",))
    assert food["list_name"] == "Categories"
    _expect_error(
        conn,
        "SELECT public.create_list(%s)",
        ("categories",),
        "already exists",
        "23505",
    )
    bound = _one(
        conn,
        "SELECT public.set_attribute_setting(%s, %s, %s)",
        (1, "Category", food["list_id"]),
    )
    assert bound["mode"] == "list"

    groceries = _one(
        conn, "SELECT public.add_list_item(%s, %s)", (food["list_id"], "Groceries")
    )
    again = _one(
        conn, "SELECT public.add_list_item(%s, %s)", (food["list_id"], " groceries ")
    )
    assert again["item_id"] == groceries["item_id"]

    saved = _one(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (
            hashes[0],
            json.dumps(
                {
                    "attribute_1": {"item_id": groceries["item_id"]},
                    "attribute_5": "free note",
                }
            ),
        ),
    )
    assert (
        saved["attribute_1"],
        saved["attribute_1_item_id"],
        saved["attribute_5"],
    ) == ("Groceries", groceries["item_id"], "free note")
    stored = conn.execute(
        "SELECT attribute_1, attribute_1_item_id FROM public.debit_d WHERE row_hash = %s",
        (hashes[0],),
    ).fetchone()
    assert stored == (
        None,
        groceries["item_id"],
    )  # the record keeps the item, not the text

    # Inline "create new item" from the row editor.
    created = _one(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (hashes[1], json.dumps({"attribute_1": {"new_item": "Card payment"}})),
    )
    assert created["attribute_1"] == "Card payment"
    catalog = _one(conn, "SELECT public.list_catalog()")
    items = {item["item_name"]: item for item in catalog["lists"][0]["items"]}
    assert set(items) == {"Groceries", "Card payment"}
    assert items["Groceries"]["used"] == 1
    assert (
        catalog["attributes"][0]["label"] == "Category"
        and catalog["attributes"][1]["mode"] == "list"
        and catalog["attributes"][4]["mode"] == "text"
    )

    # Rename once, every reader shows the new name.
    _one(conn, "SELECT public.rename_list_item(%s, %s)", (groceries["item_id"], "Food"))
    rows = _one(conn, "SELECT public.dimension_rows('debit', 'open')")["rows"]
    assert {row["row_hash"]: row["attribute_1"] for row in rows}[hashes[0]] == "Food"
    _expect_error(
        conn,
        "SELECT public.rename_list_item(%s, %s)",
        (groceries["item_id"], "card PAYMENT"),
        "already has",
        "23505",
    )
    token = _one(conn, "SELECT public.create_api_token('Sheets')")["token"]
    conn.commit()
    status, payload, _ = _gql(
        database_url,
        token,
        "{ movements(kind: DEBIT, layer: OPEN) { row_hash attribute_1 attribute_5 } }",
    )
    assert status == 200, payload
    by_hash = {row["row_hash"]: row for row in payload["data"]["movements"]}
    assert by_hash[hashes[0]]["attribute_1"] == "Food"
    assert by_hash[hashes[0]]["attribute_5"] == "free note"


def test_a_label_rename_does_not_rebind_the_slot(conn):
    _user_id, tenant_id, _debit_id, hashes = _seed_lists(conn, "bind@example.com")
    housing = _one(conn, "SELECT public.create_list('Housing')")
    result = _one(conn, "SELECT public.set_attribute_setting(1, 'Home', %s)", (housing["list_id"],))
    assert result["converted"] == 0
    assert result["list_id"] == housing["list_id"]
    assert result["mode"] == "list"
    _one(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (hashes[0], json.dumps({"attribute_1": "Rent"})),
    )
    _one(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (hashes[1], json.dumps({"attribute_1": "rent "})),
    )
    names = sorted(
        item["item_name"]
        for item in _one(conn, "SELECT public.list_catalog()")["lists"][0]["items"]
    )
    assert names == ["Rent"]
    stored = conn.execute(
        "SELECT COUNT(*) FILTER (WHERE attribute_1 IS NULL AND attribute_1_item_id IS NOT NULL) "
        "FROM public.debit_d WHERE tenant_id = %s AND row_hash = ANY(%s)",
        (tenant_id, hashes[:2]),
    ).fetchone()[0]
    assert stored == 2
    _one(conn, "SELECT public.set_attribute_setting(1, NULL, NULL)")
    still = conn.execute(
        "SELECT attribute_1_item_id IS NOT NULL FROM public.debit_d WHERE row_hash = %s",
        (hashes[0],),
    ).fetchone()[0]
    assert still is True
    _expect_error(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (hashes[0], json.dumps({"attribute_5": {"item_id": 1}})),
        "free text",
        "22023",
    )


def test_lists_are_private_per_user(conn):
    _seed_lists(conn, "owner-list@example.com")
    mine = _one(conn, "SELECT public.create_list('Mine')")
    other_user, other_tenant = _user(conn, "other-list@example.com")
    _session(conn, other_user, other_tenant)
    assert _one(conn, "SELECT public.list_catalog()")["lists"] == []
    _expect_error(
        conn,
        "SELECT public.add_list_item(%s, 'x')",
        (mine["list_id"],),
        "list not found",
        "P0002",
    )
    _expect_error(
        conn,
        "SELECT public.rename_list(%s, 'x')",
        (mine["list_id"],),
        "list not found",
        "P0002",
    )
    conn.execute("SET LOCAL ROLE strm_app")
    assert conn.execute("SELECT COUNT(*) FROM public.list_f").fetchone()[0] == 0
    conn.execute("RESET ROLE")


# --- transfers ---------------------------------------------------------------------------


def test_auto_links_same_bank_card_payment_and_inter_bank(conn):
    _seed_transfers(conn, "transfers@example.com")
    links = _links(conn)
    assert links["auto_link_transfers"] is True
    found = {
        (link["sending"]["account_number"], link["receiving"]["account_number"]): link
        for link in links["links"]
    }
    assert set(found) == {("0639", "1122"), ("0639", "3978"), ("0639", "7788")}
    assert found[("0639", "1122")]["transfer_type"] == "same_bank"
    assert found[("0639", "3978")]["transfer_type"] == "same_bank"
    assert found[("0639", "3978")]["receiving"]["kind"] == "credit"
    assert found[("0639", "7788")]["transfer_type"] == "inter_bank"
    assert all(
        link["source"] == "auto" and not link["reviewed"] for link in links["links"]
    )
    assert links["suggestions"] == []

    rows = _one(conn, "SELECT public.dimension_rows('debit', 'open')")["rows"]
    flags = {row["concept"]: row for row in rows}
    assert flags["SPEI ENVIADO 4411"]["is_internal_transfer"] is True
    assert flags["SPEI ENVIADO 4411"]["transfer_role"] == "sending"
    assert flags["SPEI ENVIADO 4411"]["transfer_counterpart_account"] == "1122"
    assert flags["COMISION 77"]["is_internal_transfer"] is False
    summary = _one(conn, "SELECT public.dimension_summary()")
    assert summary["debit"]["transfers"] == 5 and summary["credit"]["transfers"] == 1


def test_unlink_is_remembered_and_manual_link_any_two_rows(conn):
    _user_id, _tenant_id, ids = _seed_transfers(conn, "manual@example.com")
    payment = next(
        link
        for link in _links(conn)["links"]
        if link["receiving"]["account_number"] == "3978"
    )
    _one(conn, "SELECT public.unlink_transfer(%s)", (payment["link_hash"],))
    again = _one(conn, "SELECT public.detect_transfers()")
    assert again["created"] == 0  # the unlinked pair is not proposed again
    assert payment["link_hash"] not in {
        link["link_hash"] for link in _links(conn)["links"]
    }

    comision = _hash(conn, ids["A"], "COMISION%")
    deposito = _hash(conn, ids["B"], "DEPOSITO%")
    partners = _one(conn, "SELECT public.transfer_partners(%s)", (comision,))
    assert partners["partners"][0]["row_hash"] == deposito  # same amount first
    # Order does not matter: the money-out debit row becomes the sending side.
    linked = _one(conn, "SELECT public.link_transfer(%s, %s)", (deposito, comision))
    assert (linked["sending_hash"], linked["receiving_hash"], linked["source"]) == (
        comision,
        deposito,
        "manual",
    )
    _expect_error(
        conn,
        "SELECT public.link_transfer(%s, %s)",
        (comision, _hash(conn, ids["C"], "PAGO%")),
        "already linked",
        "23505",
    )
    _expect_error(
        conn,
        "SELECT public.link_transfer(%s, %s)",
        (comision, _hash(conn, ids["A"], "SPEI ENVIADO 9001%")),
        "",
        "22023",
    )
    # A re-link by hand of the unlinked pair is allowed.
    sender = _hash(conn, ids["A"], "PAGO TARJETA%")
    relinked = _one(
        conn,
        "SELECT public.link_transfer(%s, %s)",
        (sender, _hash(conn, ids["C"], "PAGO%")),
    )
    assert relinked["link_hash"] == payment["link_hash"]
    confirmed = _one(conn, "SELECT public.confirm_transfer(%s)", (linked["link_hash"],))
    assert confirmed["reviewed"] is True


def test_auto_off_only_suggests_and_installments_cannot_link(conn):
    user_id, tenant_id = _user(conn, "suggest@example.com")
    _session(conn, user_id, tenant_id)
    conn.execute(
        "UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s",
        (tenant_id,),
    )
    _one(conn, "SELECT public.set_transfer_auto(FALSE)")
    a_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    b_id = _create(conn, "bank debit", "Savings", "1122", as_of=MSI_AS_OF)
    _ingest(conn, b_id, _open_slot(conn, b_id), "statement", "b.csv", B_OPEN, MSI_AS_OF)
    _ingest(conn, a_id, _open_slot(conn, a_id), "statement", "a.csv", A_OPEN, MSI_AS_OF)
    links = _links(conn)
    assert links["links"] == []
    assert [
        (item["sending"]["account_number"], item["receiving"]["account_number"])
        for item in links["suggestions"]
    ] == [("0639", "1122")]
    created = _one(conn, "SELECT public.detect_transfers(TRUE)")
    assert created["created"] == 1
    assert len(_links(conn)["links"]) == 1


def test_auto_links_of_replaced_open_rows_are_dropped(conn):
    _user_id, _tenant_id, ids = _seed_transfers(conn, "replace@example.com")
    assert len(_links(conn)["links"]) == 3
    smaller = "Fecha,Concepto,Cargos,Abonos,Saldos\n03/11/2026,SPEI ENVIADO 4411,-250.0,0.0,750.0\n"
    _ingest(
        conn,
        ids["A"],
        _open_slot(conn, ids["A"]),
        "statement",
        "a2.csv",
        smaller,
        MSI_AS_OF,
    )
    remaining = _links(conn)["links"]
    assert [
        (link["sending"]["account_number"], link["receiving"]["account_number"])
        for link in remaining
    ] == [("0639", "1122")]


def test_graphql_transfer_flag_and_exclude(conn, database_url):
    _seed_transfers(conn, "gql-transfers@example.com")
    token = _one(conn, "SELECT public.create_api_token('Sheets')")["token"]
    conn.commit()
    query = """
    {
      all: movements(kind: DEBIT, layer: OPEN) { concept is_internal_transfer transfer_role transfer_type transfer_counterpart_account }
      kept: movements(kind: DEBIT, layer: OPEN, excludeTransfers: true) { concept }
      card: movements(kind: CREDIT, layer: OPEN) { concept is_internal_transfer transfer_source }
    }
    """
    status, payload, _ = _gql(database_url, token, query)
    assert status == 200, payload
    data = payload["data"]
    flagged = {row["concept"]: row for row in data["all"]}
    assert flagged["SPEI ENVIADO 9001"]["transfer_type"] == "inter_bank"
    assert flagged["SPEI ENVIADO 9001"]["transfer_counterpart_account"] == "7788"
    assert flagged["COMISION 77"]["is_internal_transfer"] is False
    assert sorted(row["concept"] for row in data["kept"]) == [
        "COMISION 77",
        "DEPOSITO 55",
    ]
    card = {row["concept"].strip(): row for row in data["card"]}
    assert card["PAGO 456 Referencia"]["is_internal_transfer"] is True
    assert card["PAGO 456 Referencia"]["transfer_source"] == "auto"


def test_transfers_are_private_per_user(conn):
    _seed_transfers(conn, "private-transfers@example.com")
    link = _links(conn)["links"][0]
    other_user, other_tenant = _user(conn, "nosy@example.com")
    _session(conn, other_user, other_tenant)
    assert _links(conn)["links"] == []
    _expect_error(
        conn,
        "SELECT public.unlink_transfer(%s)",
        (link["link_hash"],),
        "link not found",
        "P0002",
    )
    conn.execute("SET LOCAL ROLE strm_app")
    assert (
        conn.execute("SELECT COUNT(*) FROM public.inter_accounts_d").fetchone()[0] == 0
    )
    conn.execute("RESET ROLE")


# --- upload completeness -----------------------------------------------------------------


def test_completeness_scores_open_closed_csv_and_pdf(conn):
    user_id, tenant_id = _user(conn, "complete@example.com")
    _session(conn, user_id, tenant_id)
    conn.execute(
        "UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s",
        (tenant_id,),
    )
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    credit_id = _create(
        conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF
    )

    empty = _one(conn, "SELECT public.upload_completeness(%s)", (MSI_AS_OF,))
    assert empty["pct"] == 0 and empty["band"] == "empty"
    assert [kind["kind"] for kind in empty["kinds"]] == ["credit", "debit"]

    _ingest(
        conn,
        debit_id,
        _open_slot(conn, debit_id),
        "statement",
        "a.csv",
        A_OPEN,
        MSI_AS_OF,
    )
    october = _period(conn, debit_id, "2026-10", MSI_AS_OF)
    _ingest(
        conn,
        debit_id,
        october["cutoff_id"],
        "statement",
        "oct.csv",
        DEBIT_CSV,
        MSI_AS_OF,
    )
    report = _one(conn, "SELECT public.upload_completeness(%s)", (MSI_AS_OF,))
    debit = next(kind for kind in report["kinds"] if kind["kind"] == "debit")
    account = debit["banks"][0]["accounts"][0]
    assert [period["state"] for period in account["periods"]] == [
        "open",
        "closed",
        "closed",
    ]
    assert [period["score"] for period in account["periods"]] == [100, 75, 0]
    assert account["pct"] == pytest.approx(58.3) and account["band"] == "partial"
    assert account["periods"][1]["missing"] == "Add the PDF to certify it"

    _upload_pdf(conn, debit_id, october["cutoff_id"], "Oct.pdf", MSI_AS_OF)
    september = _period(conn, debit_id, "2026-09", MSI_AS_OF)
    _ingest(
        conn,
        debit_id,
        september["cutoff_id"],
        "statement",
        "sep.csv",
        SEP_CSV,
        MSI_AS_OF,
    )
    _upload_pdf(conn, debit_id, september["cutoff_id"], "Sep.pdf", MSI_AS_OF)
    report = _one(conn, "SELECT public.upload_completeness(%s)", (MSI_AS_OF,))
    debit = next(kind for kind in report["kinds"] if kind["kind"] == "debit")
    assert debit["pct"] == 100 and debit["band"] == "complete"
    credit = next(kind for kind in report["kinds"] if kind["kind"] == "credit")
    assert (
        credit["pct"] == 0
        and credit["banks"][0]["accounts"][0]["account_id"] == credit_id
    )
    assert report["pct"] == 50

    # Without PDF backup in the plan a closed CSV is already 100%.
    conn.execute(
        "UPDATE public.plans_d SET curated_csv_backup = FALSE WHERE plan_code = 'premium'"
    )
    _ingest(
        conn,
        credit_id,
        _open_slot(conn, credit_id),
        "statement",
        "c.csv",
        C_OPEN,
        MSI_AS_OF,
    )
    report = _one(conn, "SELECT public.upload_completeness(%s)", (MSI_AS_OF,))
    card = next(kind for kind in report["kinds"] if kind["kind"] == "credit")["banks"][
        0
    ]["accounts"][0]
    assert [period["score"] for period in card["periods"]] == [100, 0, 0]
    assert all(not period["pdf_expected"] for period in card["periods"])


def test_completeness_band_edges(conn):
    bands = conn.execute(
        "SELECT public.completeness_band(v) FROM UNNEST(ARRAY[100, 99.9, 75, 74.9, 50, 49.9, 0.1, 0]::NUMERIC[]) AS v"
    ).fetchall()
    assert [row[0] for row in bands] == [
        "complete",
        "filled",
        "filled",
        "partial",
        "partial",
        "low",
        "low",
        "empty",
    ]


def _gql(database_url, token, query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}})
    with psycopg.connect(database_url) as conn:
        return graphql_api.handle(conn, f"Bearer {token}", body, None)
