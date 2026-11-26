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


def test_a_nested_list_binds_only_to_the_next_slot(conn):
    recurring, other, nested = _bind(conn)
    _expect_error(
        conn,
        "SELECT public.set_attribute_setting(1, 'Kind', %s)",
        (nested["list_id"],),
        "Attribute 1 cannot be bound to a nested list",
        "22023",
    )
    _expect_error(
        conn,
        "SELECT public.set_attribute_setting(2, 'Place', %s)",
        (nested["list_id"],),
        "parent list first",
        "22023",
    )
    kept = _one(conn, "SELECT public.list_catalog()")
    slot2 = next(item for item in kept["attributes"] if item["slot"] == 2)
    assert slot2["list_id"] is None

    _one(conn, "SELECT public.set_attribute_setting(1, 'Kind', %s)", (other["list_id"],))
    _expect_error(
        conn,
        "SELECT public.set_attribute_setting(2, 'Place', %s)",
        (nested["list_id"],),
        "parent list first",
        "22023",
    )
    _one(conn, "SELECT public.set_attribute_setting(1, 'Kind', %s)", (recurring["list_id"],))
    saved = _one(conn, "SELECT public.set_attribute_setting(2, 'Place', %s)", (nested["list_id"],))
    assert saved["list_id"] == nested["list_id"]
    _expect_error(
        conn,
        "SELECT public.set_attribute_setting(3, 'Detail', %s)",
        (nested["list_id"],),
        "parent list first",
        "22023",
    )
    _one(conn, "SELECT public.set_attribute_setting(2, 'Kind', %s)", (recurring["list_id"],))
    _one(conn, "SELECT public.set_attribute_setting(3, 'Detail', %s)", (nested["list_id"],))
    _one(conn, "SELECT public.set_attribute_setting(2, 'Kind', %s)", (other["list_id"],))
    _expect_error(
        conn,
        "SELECT public.set_attribute_setting(3, 'Detail', %s)",
        (nested["list_id"],),
        "parent list first",
        "22023",
    )
    catalog = _one(conn, "SELECT public.list_catalog()")
    slot3 = next(item for item in catalog["attributes"] if item["slot"] == 3)
    assert slot3["list_id"] == nested["list_id"]


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
