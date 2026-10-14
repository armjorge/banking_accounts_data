from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from botocore.exceptions import ClientError

from aws_env import publish_neon_runtime_params, session
from catalog import merge_config, object_prefix, validate_environment_name

INDEX_KEY = "environments/index.json"


def _config_key(environment_name: str) -> str:
    return f"environments/{environment_name}/config.json"


def _load_json(bucket: str, region: str, key: str) -> dict[str, Any] | None:
    client = session(region).client("s3")
    try:
        body = client.get_object(Bucket=bucket, Key=key)["Body"].read()
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
            return None
        raise
    return json.loads(body.decode("utf-8"))


def _put_json(bucket: str, region: str, key: str, payload: dict[str, Any]) -> None:
    client = session(region).client("s3")
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(payload, indent=2, sort_keys=True).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="AES256",
    )


def list_environments(bucket: str, region: str) -> list[str]:
    index = _load_json(bucket, region, INDEX_KEY) or {}
    names = [validate_environment_name(name) for name in index.get("environments", [])]
    return sorted(set(names))


def save_environment(bucket: str, region: str, environment_name: str, values: dict[str, str]) -> dict[str, Any]:
    name = validate_environment_name(environment_name)
    names = list_environments(bucket, region)
    if name not in names:
        names.append(name)
        names.sort()
        _put_json(
            bucket,
            region,
            INDEX_KEY,
            {
                "environments": names,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
        )
    document = {
        "environment": name,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "values": merge_config(name, values),
    }
    _put_json(bucket, region, _config_key(name), document)
    prefix = document["values"].get("aws_object_prefix") or object_prefix(name)
    publish_neon_runtime_params(region, prefix, document["values"])
    return document


def load_environment(bucket: str, region: str, environment_name: str) -> dict[str, Any]:
    name = validate_environment_name(environment_name)
    stored = _load_json(bucket, region, _config_key(name)) or {}
    values = merge_config(name, stored.get("values"))
    return {
        "environment": name,
        "updated_at": stored.get("updated_at"),
        "values": values,
        "infra_outputs": stored.get("infra_outputs") or {},
    }


def save_infra_outputs(bucket: str, region: str, environment_name: str, outputs: dict[str, str]) -> None:
    document = load_environment(bucket, region, environment_name)
    document["infra_outputs"] = outputs
    document["updated_at"] = datetime.now(timezone.utc).isoformat()
    _put_json(bucket, region, _config_key(environment_name), document)
