"""Write-once parameters and object names for the premium curated vault.

The statements Lambda sends the same fields. The object is an extra copy:
deleting the working file in Postgres does not delete this object.

Vault names (sql/013 curated_standard_key is the source of truth; this is its mirror):

    curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{csv|pdf}

YYYY-MM is the period_end of the upload's period, account is the account number the
page shows, _msi marks the installment file, and _vN (N >= 2) is the next free version
of the same name (the vault is write-once; sql/013 curated_vault_keys_d hands them out).
Each object has a manifest at curated/{tenant}/manifest/{object file name}.json.
Objects written before sql/013 live at curated/{tenant}/{upload_id}.{ext}.
"""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote

CURATED_PREFIX = "curated"
RETENTION_DAYS = 365
SLOTS = ("statement", "installment", "pdf")
META_MAX_CHARS = 120
_UNSAFE = re.compile(r"[^A-Za-z0-9_.\-]+")
_BATCH = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


def name_part(value: object) -> str:
    """Same rule as strmStoredUploadFilename and SQL curated_name_part."""
    text = _UNSAFE.sub("_", "" if value is None else str(value))
    text = re.sub(r"_+", "_", text)
    text = re.sub(r"^_|_$", "", text)
    return text or "x"


def vault_base(*, bank_name: str, account_number: str, period_end: date, slot: str) -> str:
    """{YYYY-MM}_{account}_{Bank}[_msi] (SQL curated_vault_base)."""
    if slot not in SLOTS:
        raise ValueError("slot must be statement, installment or pdf")
    suffix = "_msi" if slot == "installment" else ""
    return f"{period_end:%Y-%m}_{name_part(account_number)}_{name_part(bank_name)}{suffix}"


def standard_object_key(
    *,
    tenant_id: str,
    bank_name: str,
    account_number: str,
    period_end: date,
    slot: str,
    version: int = 1,
) -> str:
    if version < 1:
        raise ValueError("vault version must be 1 or more")
    base = vault_base(bank_name=bank_name, account_number=account_number, period_end=period_end, slot=slot)
    version_part = f"_v{version}" if version > 1 else ""
    ext = "pdf" if slot == "pdf" else "csv"
    return f"{CURATED_PREFIX}/{tenant_id}/{base}{version_part}.{ext}"


def manifest_key(vault_key: str, suffix: str = "json") -> str:
    """curated/{tenant}/manifest/{object file name}.json (SQL vault_manifest_key)."""
    folder, _, file_name = vault_key.rpartition("/")
    return f"{folder}/manifest/{file_name}.{suffix}"


def metadata_value(value: object) -> str:
    """ASCII-safe S3 metadata value (SQL curated_meta_value): percent-encoded UTF-8."""
    return quote(("" if value is None else str(value))[:META_MAX_CHARS], safe="-_.~")


def legacy_object_key(tenant_id: str, upload_id: str, suffix: str = "csv") -> str:
    """Key used before sql/013 (kept for objects already in the vault)."""
    return f"{CURATED_PREFIX}/{tenant_id}/{upload_id}.{suffix}"


# Backwards-compatible name.
curated_object_key = legacy_object_key


def backup_object_key(current_key: str, batch: str) -> str:
    """Mirror of SQL curated_backup_key: curated/backup-{batch}/{rest of the old key}."""
    if not _BATCH.match(batch or ""):
        raise ValueError("batch must be 1-40 letters, digits, _ or -")
    if not current_key.startswith(f"{CURATED_PREFIX}/"):
        raise ValueError("current key must be under curated/")
    return f"{CURATED_PREFIX}/backup-{batch}/{current_key[len(CURATED_PREFIX) + 1:]}"


def _retain_until(now: datetime | None) -> datetime:
    moment = now or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment + timedelta(days=RETENTION_DAYS)


def curated_put_params(
    *,
    bucket: str,
    tenant_id: str,
    upload_id: str,
    body: bytes,
    now: datetime | None = None,
    suffix: str = "csv",
    key: str | None = None,
    metadata: dict[str, str] | None = None,
) -> dict[str, object]:
    """PutObject parameters. Pass key (the vault name from SQL); legacy key otherwise."""
    content_type = "application/pdf" if suffix == "pdf" else "text/csv; charset=utf-8"
    if suffix == "json":
        content_type = "application/json"
    params: dict[str, object] = {
        "Bucket": bucket,
        "Key": key or legacy_object_key(tenant_id, upload_id, suffix),
        "Body": body,
        "ContentType": content_type,
        "IfNoneMatch": "*",
        "ObjectLockMode": "GOVERNANCE",
        "ObjectLockRetainUntilDate": _retain_until(now),
        "ChecksumAlgorithm": "SHA256",
    }
    if metadata:
        params["Metadata"] = dict(metadata)
    return params


def curated_copy_params(
    *,
    bucket: str,
    source_key: str,
    target_key: str,
    now: datetime | None = None,
    metadata: dict[str, str] | None = None,
    content_type: str | None = None,
) -> dict[str, object]:
    """CopyObject parameters for the backup and new-name copies (never a move).

    With metadata the copy gets the vault metadata (MetadataDirective REPLACE);
    without it the source metadata is kept (backup copy).
    """
    if not target_key.startswith(f"{CURATED_PREFIX}/"):
        raise ValueError("target key must be under curated/")
    params: dict[str, object] = {
        "Bucket": bucket,
        "Key": target_key,
        "CopySource": {"Bucket": bucket, "Key": source_key},
        "MetadataDirective": "COPY",
        "ChecksumAlgorithm": "SHA256",
        "ObjectLockMode": "GOVERNANCE",
        "ObjectLockRetainUntilDate": _retain_until(now),
    }
    if metadata is not None:
        params["MetadataDirective"] = "REPLACE"
        params["Metadata"] = dict(metadata)
        params["ContentType"] = content_type or "application/octet-stream"
    return params
