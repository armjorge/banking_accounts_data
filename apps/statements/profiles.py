"""Multi-bank statement ingestion profiles, detection, and row normalization.

Supports CSV and XLSX. Header aliases map Fecha/FECHA, Descripción/Concepto,
Abono/Abonos, Cargo/Cargos into a unified debit/credit schema. Users can
register extra bank mappings via register_user_profile().
"""

from __future__ import annotations

import csv
import io
import re
import unicodedata
from dataclasses import dataclass, field, replace
from datetime import date, datetime
from decimal import Decimal
from typing import Any


# Logical column aliases (normalized, accent-folded, lowercase).
HEADER_ALIASES: dict[str, set[str]] = {
    "txn_date": {"fecha", "date", "fecha de operacion", "operation date"},
    "concept": {"descripcion", "concepto", "description", "concept", "detalle"},
    "income": {"abono", "abonos", "income", "credito", "deposit"},
    "outcome": {"cargo", "cargos", "outcome", "debito", "charge", "retiro"},
    "balance": {"saldo", "saldos", "balance"},
    "card_ref": {"tarjeta", "card", "card_ref"},
    "amount": {"operation", "operacion", "importe", "monto", "amount"},
}


@dataclass(frozen=True)
class Profile:
    profile_code: str
    bank_name: str
    dataset: str  # 'debit' | 'credit_monthly' | 'credit_plan'
    has_header: bool
    header_signature: list[str] | None
    column_count: int
    column_map: dict[str, Any]
    amount_rule: str
    # split_signed | split_positive_credit | single_signed | installment | split_credit_abs_income
    date_format: str = "DD/MM/YYYY"
    decimal_sep: str = "."
    thousands_sep: str = ","
    active: bool = True
    # Optional: skip rows that are section headers (BBVA Digital/Titular splits).
    skip_section_rows: bool = False
    # Prefer alias resolution over exact header_signature when True.
    use_header_aliases: bool = True
    # Required logical fields for alias detection.
    required_fields: tuple[str, ...] = ("txn_date", "concept")


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
            "outcome": "cargos",
            "income": "abonos",
            "balance": "saldos",
        },
        amount_rule="split_signed",
        required_fields=("txn_date", "concept", "income", "outcome", "balance"),
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
            "income": "abono",
            "outcome": "cargo",
            "card_ref": "tarjeta",
        },
        amount_rule="split_positive_credit",
        required_fields=("txn_date", "concept", "income", "outcome"),
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
        use_header_aliases=False,
        required_fields=("txn_date", "concept"),
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
        use_header_aliases=False,
        required_fields=("txn_date", "concept", "amount"),
    ),
    "bbva_debit_v1": Profile(
        profile_code="bbva_debit_v1",
        bank_name="BBVA",
        dataset="debit",
        has_header=True,
        # FECHA, DESCRIPCIÓN, CARGO, ABONO, SALDO (order varies; signature is sorted).
        header_signature=["abono", "cargo", "descripcion", "fecha", "saldo"],
        column_count=5,
        column_map={
            "txn_date": "fecha",
            "concept": "descripcion",
            "outcome": "cargo",
            "income": "abono",
            "balance": "saldo",
        },
        amount_rule="split_signed",
        skip_section_rows=True,
        required_fields=("txn_date", "concept", "income", "outcome", "balance"),
    ),
    "bbva_credit_v1": Profile(
        profile_code="bbva_credit_v1",
        bank_name="BBVA",
        dataset="credit_monthly",
        has_header=True,
        header_signature=["abono", "cargo", "descripcion", "fecha", "saldo"],
        column_count=5,
        column_map={
            "txn_date": "fecha",
            "concept": "descripcion",
            "outcome": "cargo",
            "income": "abono",
            "balance": "saldo",
        },
        # BBVA credit files put payments in ABONO as negative; store income as abs.
        amount_rule="split_credit_abs_income",
        skip_section_rows=True,
        required_fields=("txn_date", "concept", "income", "outcome"),
    ),
}


def register_user_profile(profile: Profile) -> None:
    """Register or replace a user-defined bank mapping (in-process)."""
    PROFILES[profile.profile_code] = profile


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


def _cell_to_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.strftime("%d/%m/%Y")
    if isinstance(value, date):
        return value.strftime("%d/%m/%Y")
    if isinstance(value, float):
        if value == int(value):
            return str(int(value))
        return str(value)
    return str(value).strip()


def parse_xlsx_bytes(payload: bytes, sheet_name: str | None = None) -> list[list[str]]:
    """Parse an XLSX workbook into string rows (first sheet or named sheet)."""
    try:
        import openpyxl
    except ImportError as exc:  # pragma: no cover
        raise ImportError("openpyxl is required to parse XLSX bank statements") from exc

    # BBVA credit exports set sheet dimension to A1 even when rows 1..N hold data;
    # read_only mode honors that and drops movements. Use normal mode.
    wb = openpyxl.load_workbook(io.BytesIO(payload), data_only=True, read_only=False)
    try:
        if sheet_name and sheet_name in wb.sheetnames:
            ws = wb[sheet_name]
        elif "Movimientos" in wb.sheetnames:
            ws = wb["Movimientos"]
        else:
            ws = wb[wb.sheetnames[0]]
        rows: list[list[str]] = []
        for raw in ws.iter_rows(values_only=True):
            cells = [_cell_to_str(c) for c in raw]
            # Drop trailing empties for column-count stability, keep at least one cell.
            while cells and cells[-1] == "":
                cells.pop()
            if any(cells):
                rows.append(cells)
        return rows
    finally:
        wb.close()


def parse_statement_bytes(payload: bytes, filename: str | None = None) -> list[list[str]]:
    """Parse CSV or XLSX bytes into rows based on filename/magic."""
    name = (filename or "").lower()
    is_xlsx = name.endswith(".xlsx") or name.endswith(".xlsm")
    if not is_xlsx and payload[:2] == b"PK":
        # ZIP/XLSX magic
        is_xlsx = True
    if is_xlsx:
        return parse_xlsx_bytes(payload)
    text, _ = decode_bytes(payload)
    return parse_csv_text(text)


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
    return bool(
        re.match(r"^\d{2}/\d{2}/\d{4}$", cleaned) or re.match(r"^\d{4}-\d{2}-\d{2}$", cleaned)
    )


def _is_section_row(row: list[str]) -> bool:
    """BBVA digital/physical split labels and footers — not movements."""
    if not row:
        return True
    first = row[0].strip()
    if not first:
        return True
    if _is_date_str(first):
        return False
    lowered = first.lower()
    if "digital" in lowered or "titular" in lowered:
        return True
    if lowered.startswith("número de tarjeta") or lowered.startswith("numero de tarjeta"):
        return True
    if lowered.startswith("cuenta:"):
        return True
    if "detalle de movimientos" in lowered:
        return True
    if "bbva" in lowered and "institución" in normalize_header_str(first):
        return True
    if "bbva" in lowered and "institucion" in normalize_header_str(first):
        return True
    return not _is_date_str(first) and len(row) <= 2


def resolve_header_aliases(headers: list[str]) -> dict[str, int]:
    """Map logical field names to column indexes using HEADER_ALIASES."""
    normalized = [normalize_header_str(h) for h in headers]
    resolved: dict[str, int] = {}
    for logical, aliases in HEADER_ALIASES.items():
        for idx, name in enumerate(normalized):
            if name in aliases and logical not in resolved:
                resolved[logical] = idx
                break
    return resolved


def _signature_from_headers(headers: list[str]) -> list[str]:
    return sorted(normalize_header_str(h) for h in headers if normalize_header_str(h))


def _find_header_row(rows: list[list[str]]) -> tuple[int, list[str]] | None:
    """Locate the header row (Fecha/FECHA + description-like column)."""
    for i, row in enumerate(rows[:15]):
        resolved = resolve_header_aliases([c for c in row if c is not None])
        if "txn_date" in resolved and "concept" in resolved:
            return i, row
    return None


def detect_profile(
    bank_name: str | None,
    rows: list[list[str]],
    dataset: str | None = None,
) -> Profile:
    """Detect statement profile matching the given bank and rows.

    Raises:
        ValueError("unsupported file"): when headers/shape don't match any profile.
        ValueError("different file than this slot accepts"): when file matches a different bank/slot.
    """
    if not rows or not rows[0]:
        raise ValueError("unsupported file")

    header_info = _find_header_row(rows)
    matched: Profile | None = None

    if header_info is not None:
        _, header_row = header_info
        signature = _signature_from_headers(header_row)
        resolved = resolve_header_aliases(header_row)

        # Exact signature match first.
        for profile in PROFILES.values():
            if not profile.active or not profile.has_header:
                continue
            if profile.header_signature == signature:
                if dataset and profile.dataset != dataset:
                    continue
                matched = profile
                break

        # Alias-based match when signature differs (e.g. FECHA vs Fecha, DESCRIPCIÓN vs Concepto).
        if matched is None:
            candidates: list[Profile] = []
            for profile in PROFILES.values():
                if not profile.active or not profile.has_header or not profile.use_header_aliases:
                    continue
                if dataset and profile.dataset != dataset:
                    continue
                if all(field in resolved for field in profile.required_fields):
                    candidates.append(profile)
            if len(candidates) == 1:
                matched = candidates[0]
            elif len(candidates) > 1 and bank_name:
                bank_l = bank_name.strip().lower()
                bank_matches = [p for p in candidates if p.bank_name.strip().lower() == bank_l]
                if dataset:
                    bank_matches = [p for p in bank_matches if p.dataset == dataset] or bank_matches
                if len(bank_matches) == 1:
                    matched = bank_matches[0]
                elif len(bank_matches) > 1 and dataset:
                    ds_matches = [p for p in bank_matches if p.dataset == dataset]
                    if len(ds_matches) == 1:
                        matched = ds_matches[0]

    # Headerless fallback: first cell is a date.
    if matched is None and _is_date_str(str(rows[0][0]).strip()):
        col_count = len(rows[0])
        for profile in PROFILES.values():
            if not profile.active or profile.has_header:
                continue
            if dataset and profile.dataset != dataset:
                continue
            if profile.column_count == col_count:
                matched = profile
                break

    if matched is None:
        raise ValueError("unsupported file")

    if bank_name is not None:
        target_bank = bank_name.strip().lower()
        if matched.bank_name.strip().lower() != target_bank:
            raise ValueError("different file than this slot accepts")

    return matched


def _col_index_for_profile(profile: Profile, headers: list[str] | None) -> dict[str, int]:
    """Build logical-field -> index map for a profile."""
    if not profile.has_header:
        return {k: int(v) for k, v in profile.column_map.items()}

    assert headers is not None
    resolved = resolve_header_aliases(headers)
    # Fill from explicit column_map names when aliases miss.
    normalized = {normalize_header_str(h): i for i, h in enumerate(headers)}
    for logical, mapped in profile.column_map.items():
        if isinstance(mapped, int):
            resolved[logical] = mapped
        else:
            key = normalize_header_str(str(mapped))
            if key in normalized and logical not in resolved:
                resolved[logical] = normalized[key]
            # Also allow map keys that are already logical aliases of themselves.
            elif key in HEADER_ALIASES.get(logical, set()) and logical not in resolved:
                for alias in HEADER_ALIASES[logical]:
                    if alias in normalized:
                        resolved[logical] = normalized[alias]
                        break
    return resolved


def _unified_item(
    *,
    txn_date: date,
    concept: str,
    income: Decimal,
    outcome: Decimal,
    balance: Decimal | None,
    amount: Decimal,
    profile: Profile,
    account_id: int | None,
    row_no: int,
    card_ref: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a normalized row with both unified and legacy DB field names."""
    item: dict[str, Any] = {
        "txn_date": txn_date,
        "concept": concept,
        "income": income,
        "outcome": outcome,
        "balance": balance,
        # Legacy names used by SQL ingest / existing tests.
        "cargos": outcome,
        "abonos": income,
        "saldos": balance,
        "amount": amount,
        "card_ref": card_ref,
        "bank_name": profile.bank_name,
        "account_id": account_id,
        "source_profile": profile.profile_code,
        "source_row_no": row_no,
        "dataset": profile.dataset,
    }
    if extra:
        item.update(extra)
    return item


def normalize_rows(
    profile: Profile,
    rows: list[list[str]],
    account_id: int | None = None,
) -> list[dict[str, Any]]:
    """Normalize raw statement rows into the unified debit/credit schema."""
    if not rows:
        return []

    header_row_idx = 0
    headers: list[str] | None = None
    data_rows: list[list[str]]
    start_row_no: int

    if profile.has_header:
        found = _find_header_row(rows)
        if found is None:
            raise ValueError("unsupported file")
        header_row_idx, header_row = found
        headers = header_row
        data_rows = rows[header_row_idx + 1 :]
        start_row_no = header_row_idx + 2
        col_index = _col_index_for_profile(profile, headers)
    else:
        data_rows = rows
        start_row_no = 1
        col_index = _col_index_for_profile(profile, None)

    normalized_list: list[dict[str, Any]] = []

    for offset, row in enumerate(data_rows):
        if not row or (len(row) == 1 and not str(row[0]).strip()):
            continue
        row_no = start_row_no + offset

        if profile.skip_section_rows and _is_section_row(row):
            continue

        # Pad short rows (BBVA sometimes has trailing empty cells stripped).
        if profile.has_header and headers is not None and len(row) < len(headers):
            row = list(row) + [""] * (len(headers) - len(row))

        if profile.amount_rule == "split_signed":
            txn_date = parse_date(row[col_index["txn_date"]])
            concept = row[col_index["concept"]]
            outcome = parse_amount(row[col_index["outcome"]])
            income = parse_amount(row[col_index["income"]])
            balance = (
                parse_amount(row[col_index["balance"]])
                if "balance" in col_index and str(row[col_index["balance"]]).strip()
                else None
            )
            amount = outcome + income
            normalized_list.append(
                _unified_item(
                    txn_date=txn_date,
                    concept=concept,
                    income=income,
                    outcome=outcome,
                    balance=balance,
                    amount=amount,
                    profile=profile,
                    account_id=account_id,
                    row_no=row_no,
                )
            )

        elif profile.amount_rule == "split_positive_credit":
            txn_date = parse_date(row[col_index["txn_date"]])
            concept = row[col_index["concept"]]
            income = abs(parse_amount(row[col_index["income"]]))
            outcome_raw = abs(parse_amount(row[col_index["outcome"]]))
            card_ref = row[col_index["card_ref"]] if "card_ref" in col_index else ""
            # Legacy: cargos negative for credit purchases (compat with prior tests/SQL).
            cargos = -outcome_raw
            abonos = income
            amount = cargos + abonos
            item = _unified_item(
                txn_date=txn_date,
                concept=concept,
                income=income,
                outcome=outcome_raw,  # unified credit: both positive
                balance=None,
                amount=amount,
                profile=profile,
                account_id=account_id,
                row_no=row_no,
                card_ref=card_ref,
                extra={
                    "cargo": outcome_raw,
                    "abono": income,
                    "cargos": cargos,
                    "abonos": abonos,
                },
            )
            normalized_list.append(item)

        elif profile.amount_rule == "split_credit_abs_income":
            # BBVA credit: CARGO +, ABONO often negative in file → store both as +.
            txn_date = parse_date(row[col_index["txn_date"]])
            concept = row[col_index["concept"]]
            income = abs(parse_amount(row[col_index["income"]]))
            outcome_raw = abs(parse_amount(row[col_index["outcome"]]))
            cargos = -outcome_raw
            abonos = income
            amount = cargos + abonos
            item = _unified_item(
                txn_date=txn_date,
                concept=concept,
                income=income,
                outcome=outcome_raw,
                balance=None,
                amount=amount,
                profile=profile,
                account_id=account_id,
                row_no=row_no,
                card_ref="",
                extra={
                    "cargo": outcome_raw,
                    "abono": income,
                    "cargos": cargos,
                    "abonos": abonos,
                },
            )
            normalized_list.append(item)

        elif profile.amount_rule == "single_signed":
            txn_date = parse_date(row[profile.column_map["txn_date"]])
            concept = row[profile.column_map["concept"]]
            raw_amt = parse_amount(row[profile.column_map["amount"]])
            if raw_amt < 0:
                outcome = raw_amt
                income = Decimal("0.00")
            else:
                outcome = Decimal("0.00")
                income = raw_amt
            amount = outcome + income
            normalized_list.append(
                _unified_item(
                    txn_date=txn_date,
                    concept=concept,
                    income=income,
                    outcome=outcome,
                    balance=None,
                    amount=amount,
                    profile=profile,
                    account_id=account_id,
                    row_no=row_no,
                )
            )

        elif profile.amount_rule == "installment":
            # Keep Banorte plan mapping via normalized header names.
            idx = {normalize_header_str(h): i for i, h in enumerate(headers or [])}
            txn_date = parse_date(row[idx["fecha de operacion"]])
            concept = row[idx["concepto"]]
            tasa_anual = parse_amount(row[idx["tasa anual"]].replace("%", ""))
            importe_inicial = parse_amount(row[idx["importe inicial"]])
            importe_pendiente = parse_amount(row[idx["importe pendiente"]])
            pagos_pendientes = row[idx["pagos pendientes"]].strip()
            mensualidad = parse_amount(row[idx["mensualidad"]])
            pagos_match = re.search(r"(\d+)\s*/\s*(\d+)", pagos_pendientes)
            pagos_hechos = int(pagos_match.group(1)) if pagos_match else None
            pagos_totales = int(pagos_match.group(2)) if pagos_match else None
            outcome = -mensualidad
            income = Decimal("0.00")
            amount = mensualidad
            normalized_list.append(
                _unified_item(
                    txn_date=txn_date,
                    concept=concept,
                    income=income,
                    outcome=outcome,
                    balance=None,
                    amount=amount,
                    profile=profile,
                    account_id=account_id,
                    row_no=row_no,
                    extra={
                        "tasa_anual": tasa_anual,
                        "importe_inicial": importe_inicial,
                        "importe_pendiente": importe_pendiente,
                        "pagos_pendientes": pagos_pendientes,
                        "pagos_hechos": pagos_hechos,
                        "pagos_totales": pagos_totales,
                        "mensualidad": mensualidad,
                    },
                )
            )
        else:
            raise ValueError(f"Unsupported amount rule: {profile.amount_rule}")

    return normalized_list
