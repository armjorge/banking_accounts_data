"""Back up curated vault objects and copy them to the standard key (sql/013).

Default is a dry run: it reads statement_uploads_f rows that have curated_s3_key and
prints, per row, the current key, the backup key and the new standard key. Nothing is
written to S3 or Postgres.

    DATABASE_URL=... uv run python scripts/curated_key_migration.py --batch 20261112

With --apply (and --confirm-bucket repeating the bucket name) each 'copy' row is:
  1. given its vault name in the registry (reserve_vault_key, committed first so a
     retry reuses it): curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{ext},
  2. copied to the backup key (curated/backup-{batch}/{tenant}/{upload_id}.{ext}),
     source metadata kept,
  3. copied to the vault name with the vault metadata (original filename, bank,
     account, period, dataset, upload id),
  4. checked (both copies have the source size and ETag),
  5. described by a manifest object curated/{tenant}/manifest/{file name}.json, then
  6. recorded with apply_curated_key_migration (curated_s3_key -> new key; the old key
     goes to curated_legacy_s3_key and the backup to curated_backup_s3_key).
The source object is never deleted: Object Lock (governance, 365 days) and the bucket
policy deny deletes under curated/*. Run --apply only after reviewing the dry run, with
the database owner URL (the plan reads every tenant) and AWS credentials for the bucket.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "apps"))

from statements.curated import (
    backup_object_key,
    curated_copy_params,
    curated_put_params,
    manifest_key,
)

PLAN_COLUMNS = (
    "upload_id",
    "tenant_id",
    "dataset",
    "chosen_filename",
    "current_key",
    "backup_key",
    "new_key",
    "manifest_key",
    "action",
)


class S3Like(Protocol):
    def head_object(self, **kwargs: Any) -> dict[str, Any]: ...

    def copy_object(self, **kwargs: Any) -> dict[str, Any]: ...

    def put_object(self, **kwargs: Any) -> dict[str, Any]: ...


def load_plan(conn: Any, batch: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        f"SELECT {', '.join(PLAN_COLUMNS)} FROM public.curated_key_migration_plan(%s)",
        (batch,),
    ).fetchall()
    plan = [dict(zip(PLAN_COLUMNS, (str(v) if v is not None else None for v in row))) for row in rows]
    for item in plan:
        if item["action"] == "copy" and item["backup_key"] != backup_object_key(item["current_key"], batch):
            raise RuntimeError(f"backup key mismatch for {item['upload_id']}")
    return plan


def format_plan(plan: list[dict[str, Any]]) -> str:
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=PLAN_COLUMNS, lineterminator="\n")
    writer.writeheader()
    for item in plan:
        writer.writerow({key: item.get(key) or "" for key in PLAN_COLUMNS})
    return out.getvalue()


def _head(s3: S3Like, bucket: str, key: str) -> dict[str, Any] | None:
    try:
        return s3.head_object(Bucket=bucket, Key=key)
    except Exception as exc:  # botocore ClientError 404 / NoSuchKey
        code = str(getattr(exc, "response", {}).get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchKey", "NotFound"}:
            return None
        raise


def _same(a: dict[str, Any], b: dict[str, Any]) -> bool:
    return a.get("ContentLength") == b.get("ContentLength") and a.get("ETag") == b.get("ETag")


def _copy_once(
    s3: S3Like,
    bucket: str,
    source: dict[str, Any],
    source_key: str,
    target_key: str,
    now: datetime,
    metadata: dict[str, str] | None = None,
) -> str:
    existing = _head(s3, bucket, target_key)
    if existing is not None:
        if not _same(existing, source):
            raise RuntimeError(f"{target_key} already exists with different content")
        return "exists"
    s3.copy_object(
        **curated_copy_params(
            bucket=bucket,
            source_key=source_key,
            target_key=target_key,
            now=now,
            metadata=metadata,
            content_type=source.get("ContentType"),
        )
    )
    written = _head(s3, bucket, target_key)
    if written is None or not _same(written, source):
        raise RuntimeError(f"copy to {target_key} could not be verified")
    return "copied"


def _put_manifest(s3: S3Like, bucket: str, key: str, manifest: dict[str, Any], now: datetime) -> str:
    if _head(s3, bucket, key) is not None:
        return "exists"
    body = json.dumps(manifest, ensure_ascii=False, indent=1, sort_keys=True, default=str).encode("utf-8")
    s3.put_object(
        **curated_put_params(bucket=bucket, tenant_id="", upload_id="", body=body, now=now, suffix="json", key=key)
    )
    return "written"


def apply_plan(
    conn: Any,
    s3: S3Like,
    bucket: str,
    plan: list[dict[str, Any]],
    *,
    now: datetime | None = None,
) -> list[dict[str, str]]:
    moment = now or datetime.now(timezone.utc)
    results = []
    for item in plan:
        if item["action"] != "copy":
            results.append({"upload_id": item["upload_id"], "result": item["action"]})
            continue
        source = _head(s3, bucket, item["current_key"])
        if source is None:
            results.append({"upload_id": item["upload_id"], "result": "missing_source"})
            continue
        new_key = conn.execute("SELECT public.reserve_vault_key(%s::uuid)", (item["upload_id"],)).fetchone()[0]
        conn.commit()
        note = "" if new_key == item["new_key"] else f" (name changed since the dry run: {new_key})"
        metadata, manifest = conn.execute(
            "SELECT public.vault_metadata(%s::uuid), public.vault_manifest(%s::uuid)",
            (item["upload_id"], item["upload_id"]),
        ).fetchone()
        backup = _copy_once(s3, bucket, source, item["current_key"], item["backup_key"], moment)
        standard = _copy_once(s3, bucket, source, item["current_key"], new_key, moment, metadata=dict(metadata))
        manifest = dict(manifest)
        manifest["vault_key"] = new_key
        manifest["legacy_key"] = item["current_key"]
        manifest["backup_key"] = item["backup_key"]
        manifest_state = _put_manifest(s3, bucket, manifest_key(new_key), manifest, moment)
        updated = conn.execute(
            "SELECT public.apply_curated_key_migration(%s::uuid, %s, %s, %s)",
            (item["upload_id"], item["current_key"], item["backup_key"], new_key),
        ).fetchone()[0]
        conn.commit()
        results.append(
            {
                "upload_id": item["upload_id"],
                "new_key": new_key,
                "result": f"backup {backup}, standard {standard}, manifest {manifest_state}, "
                + ("key updated" if updated else "row changed meanwhile, key not updated")
                + note,
            }
        )
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL"))
    parser.add_argument("--batch", default=date.today().strftime("%Y%m%d"))
    parser.add_argument("--apply", action="store_true", help="copy objects and update keys (default: dry run)")
    parser.add_argument("--bucket", default=os.environ.get("CURATED_BUCKET"))
    parser.add_argument("--confirm-bucket", default=None)
    args = parser.parse_args(argv)
    if not args.database_url:
        parser.error("--database-url or DATABASE_URL is required")
    if args.apply and (not args.bucket or args.confirm_bucket != args.bucket):
        parser.error("--apply needs --bucket and the same name in --confirm-bucket")

    import psycopg

    with psycopg.connect(args.database_url) as conn:
        plan = load_plan(conn, args.batch)
        sys.stdout.write(format_plan(plan))
        if not args.apply:
            copies = sum(1 for item in plan if item["action"] == "copy")
            sys.stderr.write(f"dry run: {copies} object(s) would be copied; nothing was written\n")
            return 0
        import boto3

        for line in apply_plan(conn, boto3.client("s3"), args.bucket, plan):
            sys.stdout.write(f"{line['upload_id']}: {line.get('new_key', '')} {line['result']}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
