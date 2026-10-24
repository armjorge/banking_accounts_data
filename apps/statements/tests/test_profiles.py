"""Pure unit tests for statement profiles, byte decoding, profile detection, and normalization."""

from decimal import Decimal
from pathlib import Path

import pytest

try:
    from statements.profiles import (
        decode_bytes,
        detect_delimiter,
        detect_profile,
        normalize_rows,
        parse_amount,
        parse_csv_text,
    )
except ImportError:
    from apps.statements.profiles import (
        decode_bytes,
        detect_delimiter,
        detect_profile,
        normalize_rows,
        parse_amount,
        parse_csv_text,
    )

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _read_fixture(name: str) -> tuple[str, str]:
    payload = (FIXTURES_DIR / name).read_bytes()
    return decode_bytes(payload)


def test_decode_encodings():
    cp1252_bytes = (FIXTURES_DIR / "banorte_credit_plan_cp1252.csv").read_bytes()
    text_cp, enc_cp = decode_bytes(cp1252_bytes)
    assert enc_cp == "windows-1252"
    assert "operación" in text_cp

    plain_text, plain_enc = _read_fixture("banorte_debit.csv")
    assert plain_enc == "utf-8"

    bom_text, bom_enc = _read_fixture("banorte_debit_utf8bom.csv")
    assert bom_enc == "utf-8"
    assert bom_text == plain_text

    u16_text, u16_enc = _read_fixture("banorte_debit_utf16le.csv")
    assert u16_enc == "utf-16le"
    assert u16_text == plain_text


def test_detect_profiles_for_fixtures():
    # Banorte debit
    text, _ = _read_fixture("banorte_debit.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    assert profile.profile_code == "banorte_debit_v1"

    # Banorte credit monthly
    text, _ = _read_fixture("banorte_credit_monthly.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    assert profile.profile_code == "banorte_credit_monthly_v1"

    # Banorte credit plan
    text, _ = _read_fixture("banorte_credit_plan_cp1252.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    assert profile.profile_code == "banorte_credit_plan_v1"

    # HSBC debit (headerless)
    text, _ = _read_fixture("hsbc_debit_noheader.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("HSBC", rows)
    assert profile.profile_code == "hsbc_debit_v1"

    # UTF-8 BOM variant
    text, _ = _read_fixture("banorte_debit_utf8bom.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    assert profile.profile_code == "banorte_debit_v1"

    # UTF-16LE variant
    text, _ = _read_fixture("banorte_debit_utf16le.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    assert profile.profile_code == "banorte_debit_v1"


def test_detect_profile_unknown_header_raises():
    text, _ = _read_fixture("unknown.csv")
    rows = parse_csv_text(text)
    with pytest.raises(ValueError, match="unsupported file"):
        detect_profile("Banorte", rows)


def test_detect_profile_mismatched_bank_raises():
    text, _ = _read_fixture("banorte_debit.csv")
    rows = parse_csv_text(text)
    with pytest.raises(ValueError, match="different file than this slot accepts"):
        detect_profile("HSBC", rows)


def test_parse_amount():
    assert parse_amount('"-1,240.00"') == Decimal("-1240.00")
    assert parse_amount("$1,240.00") == Decimal("1240.00")
    assert parse_amount("(1,240.00)") == Decimal("-1240.00")
    assert parse_amount('"-21,878.96"') == Decimal("-21878.96")
    assert parse_amount("59,871.03") == Decimal("59871.03")
    assert parse_amount("0") == Decimal("0.00")


def test_normalize_hsbc_debit_rows():
    text, _ = _read_fixture("hsbc_debit_noheader.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("HSBC", rows)
    normalized = normalize_rows(profile, rows, account_id=12)

    assert len(normalized) == 3

    # Row 1: "-21,878.96" -> cargos -21878.96, abonos 0, saldos None
    row1 = normalized[0]
    assert row1["cargos"] == Decimal("-21878.96")
    assert row1["abonos"] == Decimal("0.00")
    assert row1["saldos"] is None
    assert row1["amount"] == Decimal("-21878.96")
    assert row1["concept"] == "RETIRO CAJERO AUTOMATICO"
    assert row1["source_profile"] == "hsbc_debit_v1"

    # Row 2: "59,871.03" -> abonos 59871.03, cargos 0, saldos None
    row2 = normalized[1]
    assert row2["cargos"] == Decimal("0.00")
    assert row2["abonos"] == Decimal("59871.03")
    assert row2["saldos"] is None
    assert row2["amount"] == Decimal("59871.03")
    assert row2["concept"] == "DEPOSITO NOMINA EMPRESA"


def test_normalize_banorte_credit_monthly_rows():
    text, _ = _read_fixture("banorte_credit_monthly.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    normalized = normalize_rows(profile, rows, account_id=10)

    assert len(normalized) == 3
    # Row 2 in CSV: FARMACIA SAN PABLO, Abono: 0.00, Cargo: 99.50
    # In common schema: cargos = -99.50, abonos = 0.00, saldos = None
    row2 = normalized[1]
    assert row2["cargo"] == Decimal("99.50")
    assert row2["abono"] == Decimal("0.00")
    assert row2["cargos"] == Decimal("-99.50")
    assert row2["abonos"] == Decimal("0.00")
    assert row2["saldos"] is None
    assert row2["card_ref"] == "Titular ***1234"


def test_normalize_banorte_debit_rows():
    text, _ = _read_fixture("banorte_debit.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    normalized = normalize_rows(profile, rows, account_id=11)

    assert len(normalized) == 3
    for item in normalized:
        assert item["amount"] == item["cargos"] + item["abonos"]
        assert item["saldos"] is not None


def test_normalize_banorte_installments():
    text, _ = _read_fixture("banorte_credit_plan_cp1252.csv")
    rows = parse_csv_text(text)
    profile = detect_profile("Banorte", rows)
    normalized = normalize_rows(profile, rows, account_id=10)

    assert len(normalized) == 3
    # First row has " 03/12"
    row1 = normalized[0]
    assert row1["pagos_hechos"] == 3
    assert row1["pagos_totales"] == 12
    assert row1["mensualidad"] == Decimal("797.33")


def test_detect_delimiter():
    assert detect_delimiter("a,b,c") == ","
    assert detect_delimiter("a;b;c") == ";"
    assert detect_delimiter("a\tb\tc") == "\t"
