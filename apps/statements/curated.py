"""Write-once parameters for the premium curated CSV vault.

The statements Lambda sends the same fields. The object is an extra copy:
deleting the working file in Postgres does not delete this object.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

CURATED_PREFIX = "curated"
RETENTION_DAYS = 365


def curated_object_key(tenant_id: str, upload_id: str, suffix: str = "csv") -> str:
    return f"{CURATED_PREFIX}/{tenant_id}/{upload_id}.{suffix}"


def curated_put_params(
    *,
    bucket: str,
    tenant_id: str,
    upload_id: str,
    body: bytes,
    now: datetime | None = None,
    suffix: str = "csv",
) -> dict[str, object]:
    moment = now or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    content_type = "application/pdf" if suffix == "pdf" else "text/csv; charset=utf-8"
    return {
        "Bucket": bucket,
        "Key": curated_object_key(tenant_id, upload_id, suffix),
        "Body": body,
        "ContentType": content_type,
        "IfNoneMatch": "*",
        "ObjectLockMode": "GOVERNANCE",
        "ObjectLockRetainUntilDate": moment + timedelta(days=RETENTION_DAYS),
    }
