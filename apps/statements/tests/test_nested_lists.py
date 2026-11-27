"""sql/026: one nested list per root list, and attribute choices limited to that parent item."""

from __future__ import annotations

import json
import uuid

import psycopg
import pytest

from test_investments_assets import _add, _asset_account
from test_statement_flow import (
    MSI_AS_OF,
    _admin,
    _apply_all_ddl,
    _create,
    _current,
    _ensure_login_role,
    _expect_error,
    _ingest,
    _json,
    _session,
    _user,
)

DEBIT_CSV = (
    "Fecha,Concepto,Cargos,Abonos,Saldos\n"
    "03/11/2026,RENT PAYMENT,-100.0,0.0,900.0\n"
)
CREDIT_CSV = (
    "Fecha,Concepto,Abono,Cargo,Tarjeta\r\n"
    "03/11/2026,CARD RENT ,100.00,0,Titular ***3978\r\n"
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


def _ids(conn, kind, row_hash):
    table = {"debit": "debit_d", "credit": "credit_d", "asset": "master_closed_aaccandass_d"}[kind]
    row = conn.execute(
        f"SELECT attribute_1_item_id, attribute_2_item_id FROM public.{table} WHERE row_hash = %s",
        (row_hash,),
    ).fetchone()
    return (None, None) if row is None else (row[0], row[1])


def _catalog_list(conn, name):
    catalog = _one(conn, "SELECT public.list_catalog()")
    return next(item for item in catalog["lists"] if item["list_name"] == name)


def test_one_nested_list_and_sub_items_under_a_parent_item(conn):
    user_id, tenant_id = _user(conn, "nested@example.com")
    _session(conn, user_id, tenant_id)
    recurring = _one(conn, "SELECT public.create_list('Recurring')")
    rent = _one(conn, "SELECT public.add_list_item(%s, 'Rent')", (recurring["list_id"],))
    netflix = _one(conn, "SELECT public.add_list_item(%s, 'Netflix')", (recurring["list_id"],))
    nested = _one(conn, "SELECT public.create_nested_list(%s, 'Place')", (recurring["list_id"],))
    assert nested["parent_list_id"] == recurring["list_id"]
    assert nested["list_id"] != recurring["list_id"]

    _expect_error(
        conn,
        "SELECT public.create_nested_list(%s, 'Other')",
        (recurring["list_id"],),
        "already has a nested list",
        "23505",
    )
    _expect_error(
        conn,
        "SELECT public.create_nested_list(%s, 'Deeper')",
        (nested["list_id"],),
        "only sit under a root list",
        "22023",
    )
    assert _catalog_list(conn, "Recurring")["parent_list_id"] is None
    assert _catalog_list(conn, "Place")["parent_list_id"] == recurring["list_id"]

    apartment = _one(
        conn,
        "SELECT public.add_list_item(%s, 'Apartment', %s)",
        (nested["list_id"], rent["item_id"]),
    )
    storage = _one(
        conn,
        "SELECT public.add_list_item(%s, 'Storage', %s)",
        (nested["list_id"], rent["item_id"]),
    )
    standard_netflix = _one(
        conn,
        "SELECT public.add_list_item(%s, 'Standard', %s)",
        (nested["list_id"], netflix["item_id"]),
    )
    assert apartment["parent_item_id"] == rent["item_id"]
    assert storage["parent_item_id"] == rent["item_id"]
    assert apartment["item_id"] != storage["item_id"]
    _expect_error(
        conn,
        "SELECT public.add_list_item(%s, 'apartment', %s)",
        (nested["list_id"], rent["item_id"]),
        "already has a sub-item",
        "23505",
    )
    standard_rent = _one(
        conn,
        "SELECT public.add_list_item(%s, 'Standard', %s)",
        (nested["list_id"], rent["item_id"]),
    )
    assert standard_rent["item_id"] != standard_netflix["item_id"]
    assert standard_rent["parent_item_id"] == rent["item_id"]


def _bind(conn):
    user_id, tenant_id = _user(conn, "bind@example.com")
    _session(conn, user_id, tenant_id)
    recurring = _one(conn, "SELECT public.create_list('Recurring')")
    other = _one(conn, "SELECT public.create_list('Other')")
    nested = _one(conn, "SELECT public.create_nested_list(%s, 'Place')", (recurring["list_id"],))
    _one(conn, "SELECT public.set_attribute_setting(2, 'Note', NULL)")
    return recurring, other, nested


def test_a_note_stays_text_and_old_rows_move_onto_the_five_roles(conn):
    seeded = _movements(conn, "roles@example.com")
    people = _one(conn, "SELECT public.create_list('People')")
    ana = _one(conn, "SELECT public.add_list_item(%s, 'Ana')", (people["list_id"],))
    before = conn.execute("SELECT COUNT(*) FROM public.list_d").fetchone()[0]
    saved = _save(conn, seeded["debit"], {"attribute_5": "hello"})
    assert saved["attribute_5"] == "hello"
    assert conn.execute("SELECT COUNT(*) FROM public.list_d").fetchone()[0] == before
    conn.execute(
        """
        UPDATE public.debit_d
        SET attribute_1_item_id = %s, attribute_1 = NULL,
            attribute_2_item_id = %s, attribute_2 = NULL,
            attribute_3 = 'note', attribute_3_item_id = NULL,
            attribute_5 = NULL
        WHERE row_hash = %s
        """,
        (seeded["apartment"]["item_id"], ana["item_id"], seeded["debit"]),
    )
    conn.execute("SELECT public.migrate_five_attribute_slots()")
    row = conn.execute(
        """
        SELECT attribute_1_item_id, attribute_2_item_id, attribute_3_item_id, attribute_5
        FROM public.debit_d WHERE row_hash = %s
        """,
        (seeded["debit"],),
    ).fetchone()
    assert row == (seeded["rent"]["item_id"], seeded["apartment"]["item_id"], ana["item_id"], "note")
    conn.execute("SELECT public.migrate_five_attribute_slots()")
    again = conn.execute(
        """
        SELECT attribute_1_item_id, attribute_2_item_id, attribute_3_item_id, attribute_5
        FROM public.debit_d WHERE row_hash = %s
        """,
        (seeded["debit"],),
    ).fetchone()
    assert again == row


def test_slots_follow_list_age_and_ignore_rebinding(conn):
    recurring, other, nested = _bind(conn)
    catalog = _one(conn, "SELECT public.list_catalog()")
    by_slot = {item["slot"]: item for item in catalog["attributes"]}
    assert by_slot[1]["list_id"] == recurring["list_id"]
    assert by_slot[2]["list_id"] == nested["list_id"]
    assert by_slot[3]["list_id"] == other["list_id"]
    assert by_slot[5]["mode"] == "text"
    saved = _one(conn, "SELECT public.set_attribute_setting(2, 'Place', %s)", (other["list_id"],))
    assert saved["list_id"] == nested["list_id"]
    assert saved["label"] == "Place"
    _expect_error(conn, "SELECT public.create_list('Third')", (), "At most two lists", "22023")


def _movements(conn, email):
    user_id, tenant_id = _user(conn, email)
    _session(conn, user_id, tenant_id)
    conn.execute("UPDATE public.tenants_d SET plan_code = 'premium' WHERE tenant_id = %s", (tenant_id,))
    debit_id = _create(conn, "bank debit", "Payroll", "0639", as_of=MSI_AS_OF)
    _ingest(conn, debit_id, _current(conn, debit_id, MSI_AS_OF)["cutoff_id"], "statement", "a.csv", DEBIT_CSV, MSI_AS_OF)
    credit_id = _create(conn, "bank credit card", "Card", "3978", 6, 20, as_of=MSI_AS_OF)
    _ingest(conn, credit_id, _current(conn, credit_id, MSI_AS_OF)["cutoff_id"], "statement", "c.csv", CREDIT_CSV, MSI_AS_OF)
    asset_id = _asset_account(conn, "Cetesdirecto", "CETES")
    asset = _add(conn, asset_id, "2026-11-03", "Rent yield", abonos="10")
    debit_hash = conn.execute(
        "SELECT row_hash FROM public.movement_keys_v WHERE account_id = %s AND kind = 'debit'",
        (debit_id,),
    ).fetchone()[0]
    credit_hash = conn.execute(
        "SELECT row_hash FROM public.movement_keys_v WHERE account_id = %s AND kind = 'credit'",
        (credit_id,),
    ).fetchone()[0]
    recurring = _one(conn, "SELECT public.create_list('Recurring')")
    rent = _one(conn, "SELECT public.add_list_item(%s, 'Rent')", (recurring["list_id"],))
    netflix = _one(conn, "SELECT public.add_list_item(%s, 'Netflix')", (recurring["list_id"],))
    nested = _one(conn, "SELECT public.create_nested_list(%s, 'Place')", (recurring["list_id"],))
    apartment = _one(conn, "SELECT public.add_list_item(%s, 'Apartment', %s)", (nested["list_id"], rent["item_id"]))
    storage = _one(conn, "SELECT public.add_list_item(%s, 'Storage', %s)", (nested["list_id"], rent["item_id"]))
    standard = _one(conn, "SELECT public.add_list_item(%s, 'Standard', %s)", (nested["list_id"], netflix["item_id"]))
    _one(conn, "SELECT public.set_attribute_setting(1, 'Kind', %s)", (recurring["list_id"],))
    _one(conn, "SELECT public.set_attribute_setting(2, 'Place', %s)", (nested["list_id"],))
    return {
        "debit": debit_hash,
        "credit": credit_hash,
        "asset": asset["row_hash"],
        "rent": rent,
        "netflix": netflix,
        "nested": nested,
        "apartment": apartment,
        "storage": storage,
        "standard": standard,
    }


def _save(conn, row_hash, values):
    return _one(conn, "SELECT public.save_dimension_values(%s, %s::jsonb)", (row_hash, json.dumps(values)))


@pytest.mark.parametrize("kind", ["debit", "credit", "asset"])
def test_child_item_must_belong_to_the_selected_parent(conn, kind):
    seeded = _movements(conn, f"{kind}-nested@example.com")
    row_hash = seeded[kind]
    saved = _save(
        conn,
        row_hash,
        {"attribute_1": {"item_id": seeded["rent"]["item_id"]}, "attribute_2": {"item_id": seeded["apartment"]["item_id"]}},
    )
    assert saved["attribute_2"] == "Apartment"
    assert saved["attribute_2_item_id"] == seeded["apartment"]["item_id"]
    before = _ids(conn, kind, row_hash)
    _expect_error(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (
            row_hash,
            json.dumps(
                {
                    "attribute_1": {"item_id": seeded["rent"]["item_id"]},
                    "attribute_2": {"item_id": seeded["standard"]["item_id"]},
                }
            ),
        ),
        "does not belong",
        "22023",
    )
    assert _ids(conn, kind, row_hash) == before
    _expect_error(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (row_hash, json.dumps({"attribute_1": None, "attribute_2": {"item_id": seeded["apartment"]["item_id"]}})),
        "does not belong",
        "22023",
    )
    created = _save(
        conn,
        row_hash,
        {"attribute_1": {"item_id": seeded["rent"]["item_id"]}, "attribute_2": {"new_item": "Standard"}},
    )
    assert created["attribute_2"] == "Standard"
    parent = conn.execute(
        "SELECT parent_item_id FROM public.list_d WHERE item_id = %s",
        (created["attribute_2_item_id"],),
    ).fetchone()[0]
    assert parent == seeded["rent"]["item_id"]
    renamed = _one(conn, "SELECT public.rename_list_item(%s, 'Flat')", (seeded["apartment"]["item_id"],))
    assert renamed["item_name"] == "Flat"
    shown = _one(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (row_hash, json.dumps({"attribute_2": {"item_id": seeded["apartment"]["item_id"]}})),
    )
    assert shown["attribute_1"] == "Rent"
    assert shown["attribute_2"] == "Flat"


def test_a_sub_item_is_not_stored_on_the_list_slot(conn):
    seeded = _movements(conn, "inline-nested@example.com")
    _expect_error(
        conn,
        "SELECT public.save_dimension_values(%s, %s::jsonb)",
        (
            seeded["debit"],
            json.dumps(
                {"attribute_1": {"item_id": seeded["rent"]["item_id"], "child_item_id": seeded["apartment"]["item_id"]}}
            ),
        ),
        "sublist slot",
        "22023",
    )
    saved = _save(
        conn,
        seeded["debit"],
        {
            "attribute_1": {"item_id": seeded["rent"]["item_id"]},
            "attribute_2": {"item_id": seeded["apartment"]["item_id"]},
        },
    )
    assert saved["attribute_1"] == "Rent"
    assert saved["attribute_2"] == "Apartment"
