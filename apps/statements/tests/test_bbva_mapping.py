"""BBVA XLSX / header-alias mapping tests."""

from decimal import Decimal
from pathlib import Path

import pytest

try:
    from statements.profiles import (
        Profile,
        detect_profile,
        normalize_rows,
        parse_statement_bytes,
        register_user_profile,
        resolve_header_aliases,
    )
except ImportError:
    from apps.statements.profiles import (
        Profile,
        detect_profile,
        normalize_rows,
        parse_statement_bytes,
        register_user_profile,
        resolve_header_aliases,
    )

FIXTURES = Path(__file__).parent / "fixtures"


def test_resolve_header_aliases_fecha_descripcion():
    resolved = resolve_header_aliases(["FECHA", "DESCRIPCIÓN", "CARGO", "ABONO", "SALDO"])
    assert resolved["txn_date"] == 0
    assert resolved["concept"] == 1
    assert resolved["outcome"] == 2
    assert resolved["income"] == 3
    assert resolved["balance"] == 4


def test_bbva_debit_xlsx_detect_and_normalize():
    payload = (FIXTURES / "bbva_debit_2026-09.xlsx").read_bytes()
    rows = parse_statement_bytes(payload, "bbva_debit_2026-09.xlsx")
    profile = detect_profile("BBVA", rows, dataset="debit")
    assert profile.profile_code == "bbva_debit_v1"
    normalized = normalize_rows(profile, rows, account_id=1)
    assert len(normalized) >= 4
    # First movement in fixture: PAGO TARJETA (cargo negative) 
    first = normalized[0]
    assert first["txn_date"].isoformat() == "2026-09-30"
    assert first["outcome"] < 0 or first["income"] > 0
    assert first["balance"] is not None
    assert first["income"] >= 0 or first["outcome"] <= 0


def test_bbva_credit_skips_digital_titular_rows():
    payload = (FIXTURES / "bbva_credit_2026-09.xlsx").read_bytes()
    rows = parse_statement_bytes(payload, "bbva_credit_2026-09.xlsx")
    profile = detect_profile("BBVA", rows, dataset="credit_monthly")
    assert profile.profile_code == "bbva_credit_v1"
    normalized = normalize_rows(profile, rows, account_id=2)
    concepts = [r["concept"] for r in normalized]
    assert all("Digital" not in c and "Titular" not in c for c in concepts)
    assert any("FIESTA REWARDS" in c for c in concepts)
    # Payment row: income positive after abs()
    pago = next(r for r in normalized if "BMOVIL" in r["concept"])
    assert pago["income"] > 0
    assert pago["balance"] is None
    assert pago["outcome"] == Decimal("0.00") or pago["income"] > 0


def test_register_user_profile():
    custom = Profile(
        profile_code="custom_demo_v1",
        bank_name="DemoBank",
        dataset="debit",
        has_header=True,
        header_signature=["fecha", "concepto", "abono", "cargo"],
        column_count=4,
        column_map={
            "txn_date": "fecha",
            "concept": "concepto",
            "income": "abono",
            "outcome": "cargo",
        },
        amount_rule="split_signed",
        required_fields=("txn_date", "concept", "income", "outcome"),
    )
    register_user_profile(custom)
    rows = [
        ["Fecha", "Concepto", "Abono", "Cargo"],
        ["01/10/2026", "DEMO CHARGE", "0.00", "-10.00"],
    ]
    profile = detect_profile("DemoBank", rows, dataset="debit")
    assert profile.profile_code == "custom_demo_v1"
    out = normalize_rows(profile, rows)
    assert len(out) == 1
    assert out[0]["outcome"] == Decimal("-10.00")
