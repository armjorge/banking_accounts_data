"""Pure mirrors of the file-catcher rules in sql/006_statement_flow.sql and sql/011_open_future_ledgers.sql."""

from __future__ import annotations

import calendar
import hashlib
import re
import unicodedata
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal


from statements.profiles import (
    decode_bytes as _decode_bytes,
    normalize_header as _normalize_header,
)


_ACCENT_FOLD = str.maketrans(
    "ÁÀÂÄÃÅáàâäãåÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÖÕóòôöõÚÙÛÜúùûüÑñÇç",
    "AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuNnCc",
)


def concept_sk(concept: str) -> str:
    """Digits from the trimmed concept, or (no digit) its letters A-Z, upper-cased with
    accents folded (sql/018 public.concept_sk)."""
    trimmed = concept.replace("\u00a0", " ").replace("\ufeff", "").strip()
    if any("0" <= char <= "9" for char in trimmed):
        return "".join(char for char in trimmed if "0" <= char <= "9")
    folded = trimmed.translate(_ACCENT_FOLD)
    return "".join(char for char in folded if "a" <= char <= "z" or "A" <= char <= "Z").upper()


def concept_hash_key(concept: str) -> str:
    return concept_sk(concept)


def normalize_header(header: str) -> str:
    res = _normalize_header(header)
    return res if isinstance(res, str) else " ".join(res)


def decode_bank_csv(payload: bytes) -> str:
    """UTF-8 / BOM / Windows-1252. Fold non-breaking spaces."""
    text, _ = _decode_bytes(payload)
    return text


def movement_row_hash(
    txn_date: date,
    account_number: str,
    amount: Decimal | int | str,
    concept_key: str,
    occurrence: int,
) -> str:
    rounded = Decimal(str(amount)).quantize(Decimal("0.01"))
    sign = "-" if rounded < 0 else ""
    absolute = abs(rounded)
    whole = int(absolute)
    cents = int((absolute - Decimal(whole)) * 100)
    amount_text = f"{sign}{whole}.{cents:02d}"
    payload = f"{txn_date.isoformat()}|{account_number}|{amount_text}|{concept_key}|{occurrence}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def movement_amount_text(amount: Decimal | int | str | None) -> str:
    """Two decimals, '-' only for negatives, never '-0.00' (sql/014 movement_amount_text)."""
    # ROUND_HALF_UP is half away from zero, like PostgreSQL ROUND(numeric, 2).
    rounded = Decimal(str(amount if amount is not None else 0)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    if rounded == 0:
        return "0.00"
    return f"{rounded:f}"


def movement_row_hash_v2(
    user_id: str,
    account_id: int,
    bank_id: int,
    txn_date: date,
    concept_key: str,
    abonos: Decimal | int | str,
    cargos: Decimal | int | str,
    occurrence: int,
) -> str:
    """Mirror of public.movement_row_hash_v2 (sql/014, docs/row_hash.md)."""
    payload = "|".join(
        (
            str(user_id).lower(),
            str(int(account_id)),
            str(int(bank_id)),
            txn_date.isoformat(),
            concept_key,
            movement_amount_text(abonos),
            movement_amount_text(cargos),
            str(int(occurrence)),
        )
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def period_bounds(
    *,
    allows_cutoff: bool,
    cutoff_day: int | None,
    year: int,
    month: int,
) -> tuple[date, date]:
    if not allows_cutoff:
        start = date(year, month, 1)
        end = date(year, month, calendar.monthrange(year, month)[1])
        return start, end
    if cutoff_day is None or not 1 <= cutoff_day <= 31:
        raise ValueError("Credit card accounts require a cutoff day from 1 to 31")
    end = date(year, month, min(cutoff_day, calendar.monthrange(year, month)[1]))
    previous_year, previous_month = (year - 1, 12) if month == 1 else (year, month - 1)
    previous_end = date(
        previous_year,
        previous_month,
        min(cutoff_day, calendar.monthrange(previous_year, previous_month)[1]),
    )
    return previous_end + timedelta(days=1), end


def catcher_periods(
    *,
    allows_cutoff: bool,
    cutoff_day: int | None,
    as_of: date,
) -> list[tuple[date, date]]:
    """The latest closed period and the two before it, oldest first."""
    year, month = as_of.year, as_of.month
    found: list[tuple[date, date]] = []
    for _ in range(36):
        start, end = period_bounds(
            allows_cutoff=allows_cutoff,
            cutoff_day=cutoff_day,
            year=year,
            month=month,
        )
        if as_of > end:
            found.append((start, end))
        if len(found) == 3:
            break
        month -= 1
        if month == 0:
            month = 12
            year -= 1
    found.reverse()
    return found


def current_period(
    *,
    allows_cutoff: bool,
    cutoff_day: int | None,
    as_of: date,
) -> tuple[date, date]:
    """The open period that contains ``as_of`` (mirror of public.current_period in 011).

    Debit: the calendar month. Credit: the day after the last cutoff through the next cutoff.
    """
    start, end = period_bounds(
        allows_cutoff=allows_cutoff,
        cutoff_day=cutoff_day,
        year=as_of.year,
        month=as_of.month,
    )
    if as_of > end:
        year, month = (as_of.year + 1, 1) if as_of.month == 12 else (as_of.year, as_of.month + 1)
        start, end = period_bounds(
            allows_cutoff=allows_cutoff,
            cutoff_day=cutoff_day,
            year=year,
            month=month,
        )
    return start, end


def future_cutoff_periods(
    *,
    cutoff_day: int,
    as_of: date,
    count: int,
) -> list[tuple[date, date]]:
    """The next ``count`` credit cycles whose cutoff is strictly after ``as_of`` (011)."""
    if count < 1:
        return []
    _, end = current_period(allows_cutoff=True, cutoff_day=cutoff_day, as_of=as_of)
    year, month = end.year, end.month
    if end <= as_of:
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    found: list[tuple[date, date]] = []
    for _ in range(count):
        found.append(
            period_bounds(allows_cutoff=True, cutoff_day=cutoff_day, year=year, month=month)
        )
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return found


def installment_counts(pagos_pendientes: str) -> tuple[int, int] | None:
    """Banorte "Pagos pendientes" NN/MM -> (payments still due, payments in the plan)."""
    match = re.fullmatch(r"\s*(\d+)\s*/\s*(\d+)\s*", pagos_pendientes or "")
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))
