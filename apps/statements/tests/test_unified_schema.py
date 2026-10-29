"""Unified debit/credit schema + user mapping + open-replace semantics (no DB)."""

from decimal import Decimal
from pathlib import Path

import pytest

try:
    from statements.profiles import (
        build_user_profile,
        detect_profile,
        normalize_rows,
        open_accounts_touched,
        parse_csv_text,
        parse_statement_bytes,
        register_user_profile,
    )
except ImportError:
    from apps.statements.profiles import (
        build_user_profile,
        detect_profile,
        normalize_rows,
        open_accounts_touched,
        parse_csv_text,
        parse_statement_bytes,
        register_user_profile,
    )

FIX = Path(__file__).parent / "fixtures"


def _assert_debit_unified(rows):
    for r in rows:
        assert r["income"] >= 0
        assert r["outcome"] <= 0
        # Balance from file when present; HSBC has none.


def _assert_credit_unified(rows):
    for r in rows:
        assert r["income"] >= 0
        assert r["outcome"] >= 0
        assert r["balance"] is None


def test_banorte_debit_unified_signs():
    text = (FIX / "banorte_debit.csv").read_text(encoding="utf-8")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows, dataset="debit")
    out = normalize_rows(profile, rows)
    assert profile.amount_rule == "split_signed"
    _assert_debit_unified(out)
    assert any(r["balance"] is not None for r in out)
    assert any(r["outcome"] < 0 for r in out)
    assert any(r["income"] > 0 for r in out)


def test_banorte_credit_both_positive():
    text = (FIX / "banorte_credit_monthly.csv").read_text(encoding="utf-8")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows, dataset="credit_monthly")
    out = normalize_rows(profile, rows)
    assert profile.amount_rule == "split_positive_credit"
    _assert_credit_unified(out)
    assert any(r["income"] > 0 for r in out)
    assert any(r["outcome"] > 0 for r in out)


def test_hsbc_debit_single_signed_split():
    text = (FIX / "hsbc_debit_noheader.csv").read_text(encoding="utf-8")
    rows = parse_csv_text(text)
    profile = detect_profile("HSBC", rows, dataset="debit")
    out = normalize_rows(profile, rows)
    assert profile.amount_rule == "single_signed"
    assert profile.has_header is False
    _assert_debit_unified(out)
    # Headerless source has no running balance column.
    assert all(r["balance"] is None for r in out)
    assert out[0]["outcome"] == Decimal("-21878.96")
    assert out[1]["income"] == Decimal("59871.03")


def test_bbva_debit_and_credit_unified():
    debit_rows = parse_statement_bytes(
        (FIX / "bbva_debit_2026-09.xlsx").read_bytes(), "bbva_debit_2026-09.xlsx"
    )
    debit = normalize_rows(detect_profile("BBVA", debit_rows, dataset="debit"), debit_rows)
    _assert_debit_unified(debit)
    assert any(r["balance"] is not None for r in debit)

    credit_rows = parse_statement_bytes(
        (FIX / "bbva_credit_2026-09.xlsx").read_bytes(), "bbva_credit_2026-09.xlsx"
    )
    credit = normalize_rows(
        detect_profile("BBVA", credit_rows, dataset="credit_monthly"), credit_rows
    )
    _assert_credit_unified(credit)
    pago = next(r for r in credit if "BMOVIL" in r["concept"])
    assert pago["income"] > 0


def test_build_and_register_user_bank_mapping():
    profile = build_user_profile(
        profile_code="demo_bank_debit_v1",
        bank_name="DemoBank",
        dataset="debit",
        amount_rule="split_signed",
        column_map={
            "txn_date": "Fecha",
            "concept": "Concepto",
            "income": "Abono",
            "outcome": "Cargo",
            "balance": "Saldo",
        },
    )
    register_user_profile(profile)
    rows = [
        ["Fecha", "Concepto", "Abono", "Cargo", "Saldo"],
        ["02/10/2026", "DEMO IN", "100.00", "0.00", "1100.00"],
        ["03/10/2026", "DEMO OUT", "0.00", "-40.00", "1060.00"],
    ]
    detected = detect_profile("DemoBank", rows, dataset="debit")
    assert detected.profile_code == "demo_bank_debit_v1"
    out = normalize_rows(detected, rows)
    assert len(out) == 2
    _assert_debit_unified(out)
    assert out[0]["income"] == Decimal("100.00")
    assert out[1]["outcome"] == Decimal("-40.00")


def test_open_accounts_touched_only_payload_accounts():
    payload = {
        "debit": [
            {"account_number": "111", "txn_date": "2026-10-01", "concept": "A", "income": 0, "outcome": -1},
            {"account_number": "222", "txn_date": "2026-10-01", "concept": "B", "income": 5, "outcome": 0},
        ],
        "credit": [
            {"account_number": "333", "txn_date": "2026-10-01", "concept": "C", "income": 10, "outcome": 0},
        ],
    }
    touched = open_accounts_touched(payload)
    assert touched == {"111", "222", "333"}
    # Uploading one account only touches that one (others stay).
    one = open_accounts_touched({"debit": [{"account_number": "111", "txn_date": "2026-10-01", "concept": "A"}]})
    assert one == {"111"}
    assert open_accounts_touched({"debit": [], "credit": []}) == set()


def test_build_user_profile_rejects_bad_rule():
    with pytest.raises(ValueError, match="amount_rule"):
        build_user_profile(
            profile_code="x",
            bank_name="Y",
            dataset="debit",
            amount_rule="nope",
            column_map={"txn_date": "Fecha", "concept": "C"},
        )
