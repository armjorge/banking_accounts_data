"""Multi-bank statement ingestion profiles, detection, and row normalization."""

from __future__ import annotations

import csv
import io
import re
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal
from typing import Any


@dataclass(frozen=True)
class Profile:
    profile_code: str
    bank_name: str
    dataset: str  # 'debit' | 'credit_monthly' | 'credit_plan'
    has_header: bool
    header_signature: list[str] | None
    column_count: int
    column_map: dict[str, Any]
    amount_rule: str  # 'split_signed' | 'split_positive_credit' | 'single_signed' | 'installment'
    date_format: str = "DD/MM/YYYY"
    decimal_sep: str = "."
    thousands_sep: str = ","
    active: bool = True


PROFILES: dict[str, Profile] = {
    "banorte_debit_v1": Profile(
        profile_code="banorte_debit_v1",
        bank_name="Banorte",
        dataset="debit",
        has_header=True,
        header_signature=["abonos", "cargos", "concepto", "fecha", "saldos"],
        column_count=5,
        column_map={
            "txn_date": "fecha",
            "concept": "concepto",
            "cargos": "cargos",
            "abonos": "abonos",
            "saldos": "saldos",
        },
        amount_rule="split_signed",
        date_format="DD/MM/YYYY",
        decimal_sep=".",
        thousands_sep=",",
        active=True,
    ),
    "banorte_credit_monthly_v1": Profile(
        profile_code="banorte_credit_monthly_v1",
        bank_name="Banorte",
        dataset="credit_monthly",
        has_header=True,
        header_signature=["abono", "cargo", "concepto", "fecha", "tarjeta"],
        column_count=5,
        column_map={
            "txn_date": "fecha",
            "concept": "concepto",
            "abono": "abono",
            "cargo": "cargo",
            "tarjeta": "tarjeta",
        },
        amount_rule="split_positive_credit",
        date_format="DD/MM/YYYY",
        decimal_sep=".",
        thousands_sep=",",
        active=True,
    ),
    "banorte_credit_plan_v1": Profile(
        profile_code="banorte_credit_plan_v1",
        bank_name="Banorte",
        dataset="credit_plan",
        has_header=True,
        header_signature=[
            "concepto",
            "fecha de operacion",
            "importe inicial",
            "importe pendiente",
            "mensualidad",
            "pagos pendientes",
            "tasa anual",
        ],
        column_count=7,
        column_map={
            "txn_date": "fecha de operacion",
            "concept": "concepto",
            "tasa_anual": "tasa anual",
            "importe_inicial": "importe inicial",
            "importe_pendiente": "importe pendiente",
            "pagos_pendientes": "pagos pendientes",
            "mensualidad": "mensualidad",
        },
        amount_rule="installment",
        date_format="DD/MM/YYYY",
        decimal_sep=".",
        thousands_sep=",",
        active=True,
    ),
    "hsbc_debit_v1": Profile(
        profile_code="hsbc_debit_v1",
        bank_name="HSBC",
        dataset="debit",
        has_header=False,
        header_signature=None,
        column_count=3,
        column_map={"txn_date": 0, "concept": 1, "amount": 2},
        amount_rule="single_signed",
        date_format="DD/MM/YYYY",
        decimal_sep=".",
        thousands_sep=",",
        active=True,
    ),
}


def normalize_header_str(text: str) -> str:
    """Normalize a single column header: strip BOM, NBSP, accents, lowercase, trim."""
    cleaned = text.replace("\u00a0", " ").replace("\ufeff", "").strip().lower()
    folded = unicodedata.normalize("NFD", cleaned)
    without_marks = "".join(char for char in folded if unicodedata.category(char) != "Mn")
    return re.sub(r"\s+", " ", without_marks).strip()


def normalize_header(header: str | list[str]) -> str | list[str]:
    """Compatibility wrapper: normalize a single header string or a list of headers."""
    if isinstance(header, list):
        return [normalize_header_str(col) for col in header]
    return normalize_header_str(header)


def decode_bytes(payload: bytes) -> tuple[str, str]:
    """Decode raw bytes detecting BOM (UTF-8, UTF-16LE, UTF-16BE), UTF-8 strict, or CP1252."""
    if payload.startswith(b"\xef\xbb\xbf"):
        text = payload[3:].decode("utf-8")
        encoding = "utf-8"
    elif payload.startswith(b"\xff\xfe"):
        text = payload[2:].decode("utf-16le")
        encoding = "utf-16le"
    elif payload.startswith(b"\xfe\xff"):
        text = payload[2:].decode("utf-16be")
        encoding = "utf-16be"
    else:
        try:
            text = payload.decode("utf-8")
            encoding = "utf-8"
        except UnicodeDecodeError:
            text = payload.decode("cp1252")
            encoding = "windows-1252"
    cleaned = text.replace("\u00a0", " ").lstrip("\ufeff")
    return cleaned, encoding


def detect_delimiter(first_line: str) -> str:
    """Detect delimiter (, ; tab) from the first line."""
    semis = first_line.count(";")
    tabs = first_line.count("\t")
    commas = first_line.count(",")
    if semis > commas and semis > tabs:
        return ";"
    if tabs > commas and tabs > semis:
        return "\t"
    return ","


def parse_csv_text(text: str, delimiter: str | None = None) -> list[list[str]]:
    """Parse text into rows using csv.reader."""
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n")
    if not cleaned.strip():
        return []
    first_line = cleaned.split("\n", 1)[0]
    delim = delimiter or detect_delimiter(first_line)
    reader = csv.reader(io.StringIO(cleaned), delimiter=delim)
    return [row for row in reader if any(field.strip() for field in row)]


def parse_amount(value: str | int | float | Decimal) -> Decimal:
    """Parse amounts with optional quotes, $, commas, parentheses negatives."""
    if isinstance(value, Decimal):
        return value.quantize(Decimal("0.01"))
    if isinstance(value, (int, float)):
        return Decimal(str(value)).quantize(Decimal("0.01"))
    text = str(value).strip().strip('"').strip("'")
    text = text.replace("\u00a0", "").replace(" ", "").replace("$", "")
    if not text:
        return Decimal("0.00")
    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative = True
        text = text[1:-1].strip()
    if text.startswith("-"):
        negative = True
        text = text[1:].strip()
    elif text.startswith("+"):
        text = text[1:].strip()

    if "." in text and "," in text:
        if text.rfind(",") > text.rfind("."):
            text = text.replace(".", "").replace(",", ".")
        else:
            text = text.replace(",", "")
    elif "," in text:
        if re.fullmatch(r"\d{1,3}(,\d{3})+", text):
            text = text.replace(",", "")
        else:
            text = text.replace(",", ".")
    elif re.fullmatch(r"\d{1,3}(\.\d{3})+", text):
        text = text.replace(".", "")

    result = Decimal(text).quantize(Decimal("0.01"))
    return -result if negative else result


def parse_date(date_str: str) -> date:
    """Parse DD/MM/YYYY or YYYY-MM-DD into a date object."""
    cleaned = date_str.strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}$", cleaned):
        return datetime.strptime(cleaned, "%Y-%m-%d").date()
    if re.match(r"^\d{2}/\d{2}/\d{4}$", cleaned):
        return datetime.strptime(cleaned, "%d/%m/%Y").date()
    raise ValueError(f"Unreadable date: {date_str}")


def _is_date_str(val: str) -> bool:
    cleaned = val.strip()
    return bool(re.match(r"^\d{2}/\d{2}/\d{4}$", cleaned) or re.match(r"^\d{4}-\d{2}-\d{2}$", cleaned))


def detect_profile(bank_name: str | None, rows: list[list[str]]) -> Profile:
    """Detect statement profile matching the given bank and rows.

    Raises:
        ValueError("unsupported file"): when headers/shape don't match any profile.
        ValueError("different file than this slot accepts"): when file matches a different bank/slot.
    """
    if not rows or not rows[0]:
        raise ValueError("unsupported file")

    first_row = [str(col).strip() for col in rows[0]]
    first_row_normalized = [normalize_header_str(c) for c in first_row]
    signature = sorted(first_row_normalized)

    # 1. Try matching by header signature across all active profiles
    matched: Profile | None = None
    for profile in PROFILES.values():
        if profile.active and profile.has_header and profile.header_signature == signature:
            matched = profile
            break

    # 2. Headerless fallback: if col 1 parses as date and column count matches
    if matched is None and _is_date_str(first_row[0]):
        col_count = len(first_row)
        for profile in PROFILES.values():
            if profile.active and not profile.has_header and profile.column_count == col_count:
                matched = profile
                break

    if matched is None:
        raise ValueError("unsupported file")

    if bank_name is not None:
        target_bank = bank_name.strip().lower()
        if matched.bank_name.strip().lower() != target_bank:
            raise ValueError("different file than this slot accepts")

    return matched


def normalize_rows(
    profile: Profile,
    rows: list[list[str]],
    account_id: int | None = None,
) -> list[dict[str, Any]]:
    """Transform rows of the detected profile into the common normalized schema."""
    if not rows:
        return []

    normalized_list: list[dict[str, Any]] = []

    if profile.has_header:
        headers = [normalize_header_str(c) for c in rows[0]]
        col_index = {name: idx for idx, name in enumerate(headers)}
        data_rows = rows[1:]
        start_row_no = 2
    else:
        col_index = {}
        data_rows = rows
        start_row_no = 1

    for offset, row in enumerate(data_rows):
        if not row or (len(row) == 1 and not row[0].strip()):
            continue
        row_no = start_row_no + offset

        if len(row) != profile.column_count:
            raise ValueError(
                f"Row {row_no} column count {len(row)} does not match expected {profile.column_count}"
            )

        if profile.amount_rule == "split_signed":
            # Banorte debit
            txn_date = parse_date(row[col_index["fecha"]])
            concept = row[col_index["concepto"]]
            cargos = parse_amount(row[col_index["cargos"]])
            abonos = parse_amount(row[col_index["abonos"]])
            saldos = parse_amount(row[col_index["saldos"]])
            amount = cargos + abonos
            card_ref = None
            item = {
                "txn_date": txn_date,
                "concept": concept,
                "cargos": cargos,
                "abonos": abonos,
                "saldos": saldos,
                "amount": amount,
                "card_ref": card_ref,
                "bank_name": profile.bank_name,
                "account_id": account_id,
                "source_profile": profile.profile_code,
                "source_row_no": row_no,
            }

        elif profile.amount_rule == "split_positive_credit":
            # Banorte credit monthly
            txn_date = parse_date(row[col_index["fecha"]])
            concept = row[col_index["concepto"]]
            abono = parse_amount(row[col_index["abono"]])
            cargo = parse_amount(row[col_index["cargo"]])
            tarjeta = row[col_index["tarjeta"]]
            cargos = -cargo
            abonos = abono
            saldos = None
            amount = cargos + abonos
            card_ref = tarjeta
            item = {
                "txn_date": txn_date,
                "concept": concept,
                "cargos": cargos,
                "abonos": abonos,
                "saldos": saldos,
                "amount": amount,
                "cargo": cargo,
                "abono": abono,
                "card_ref": card_ref,
                "bank_name": profile.bank_name,
                "account_id": account_id,
                "source_profile": profile.profile_code,
                "source_row_no": row_no,
            }

        elif profile.amount_rule == "single_signed":
            # HSBC debit
            txn_date = parse_date(row[profile.column_map["txn_date"]])
            concept = row[profile.column_map["concept"]]
            raw_amt = parse_amount(row[profile.column_map["amount"]])
            if raw_amt < 0:
                cargos = raw_amt
                abonos = Decimal("0.00")
            else:
                cargos = Decimal("0.00")
                abonos = raw_amt
            saldos = None
            amount = cargos + abonos
            card_ref = None
            item = {
                "txn_date": txn_date,
                "concept": concept,
                "cargos": cargos,
                "abonos": abonos,
                "saldos": saldos,
                "amount": amount,
                "card_ref": card_ref,
                "bank_name": profile.bank_name,
                "account_id": account_id,
                "source_profile": profile.profile_code,
                "source_row_no": row_no,
            }

        elif profile.amount_rule == "installment":
            # Banorte credit plan
            txn_date = parse_date(row[col_index["fecha de operacion"]])
            concept = row[col_index["concepto"]]
            tasa_anual = parse_amount(row[col_index["tasa anual"]].replace("%", ""))
            importe_inicial = parse_amount(row[col_index["importe inicial"]])
            importe_pendiente = parse_amount(row[col_index["importe pendiente"]])
            pagos_pendientes = row[col_index["pagos pendientes"]].strip()
            mensualidad = parse_amount(row[col_index["mensualidad"]])

            pagos_match = re.search(r"(\d+)\s*/\s*(\d+)", pagos_pendientes)
            if pagos_match:
                pagos_hechos = int(pagos_match.group(1))
                pagos_totales = int(pagos_match.group(2))
            else:
                pagos_hechos = None
                pagos_totales = None

            cargos = -mensualidad
            abonos = Decimal("0.00")
            saldos = None
            amount = mensualidad
            card_ref = None
            item = {
                "txn_date": txn_date,
                "concept": concept,
                "cargos": cargos,
                "abonos": abonos,
                "saldos": saldos,
                "amount": amount,
                "tasa_anual": tasa_anual,
                "importe_inicial": importe_inicial,
                "importe_pendiente": importe_pendiente,
                "pagos_pendientes": pagos_pendientes,
                "pagos_hechos": pagos_hechos,
                "pagos_totales": pagos_totales,
                "mensualidad": mensualidad,
                "card_ref": card_ref,
                "bank_name": profile.bank_name,
                "account_id": account_id,
                "source_profile": profile.profile_code,
                "source_row_no": row_no,
            }
        else:
            raise ValueError(f"Unsupported amount rule: {profile.amount_rule}")

        normalized_list.append(item)

    return normalized_list
