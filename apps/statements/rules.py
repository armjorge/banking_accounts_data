"""Pure mirrors of the file-catcher rules in sql/006_statement_flow.sql."""

from __future__ import annotations

import calendar
import hashlib
import re
import unicodedata
from datetime import date, timedelta
from decimal import Decimal


from statements.profiles import (
    decode_bytes as _decode_bytes,
    normalize_header as _normalize_header,
)


def concept_sk(concept: str) -> str:
    """Digits from the trimmed concept, or letters when the concept has no digit."""
    trimmed = concept.replace("\u00a0", " ").replace("\ufeff", "").strip()
    if any("0" <= char <= "9" for char in trimmed):
        return "".join(char for char in trimmed if "0" <= char <= "9")
    return "".join(char for char in trimmed if char.isalpha())


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
