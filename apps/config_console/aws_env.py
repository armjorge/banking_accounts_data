from __future__ import annotations

from dataclasses import dataclass

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from catalog import PROJECT

CONTROL_PREFIX = "/strm_bank/control"


@dataclass
class AwsIdentity:
    account: str
    arn: str
    user_id: str
    region: str


def session(region: str | None = None):
    return boto3.session.Session(region_name=region or None)


def caller_identity(region: str = "us-east-1") -> AwsIdentity:
    try:
        sts = session(region).client("sts")
        identity = sts.get_caller_identity()
    except Exception as exc:  # noqa: BLE001
        message = str(exc)
        if "botocore[crt]" in message or "login credential provider" in message.lower():
            raise RuntimeError(
                'aws login credentials need the CRT extra. From the repo root run: uv sync',
            ) from exc
        raise
    return AwsIdentity(
        account=identity["Account"],
        arn=identity["Arn"],
        user_id=identity["UserId"],
        region=region,
    )


def publish_neon_runtime_params(region: str, prefix: str, values: dict[str, str]) -> None:
    """SSM values the Cognito trigger Lambda reads on signup/signin."""
    path = prefix if prefix.startswith("/") else f"/{prefix}"
    ssm = session(region).client("ssm")
    schema = values.get("neon_users_schema") or "cognito_users"
    ssm.put_parameter(
        Name=f"{path}/neon_users_schema",
        Value=schema,
        Type="String",
        Overwrite=True,
    )
    url = values.get("neon_database_url") or ""
    if url:
        ssm.put_parameter(
            Name=f"{path}/neon_database_url",
            Value=url,
            Type="SecureString",
            Overwrite=True,
        )


def control_config_bucket(region: str) -> str:
    ssm = session(region).client("ssm")
    try:
        return ssm.get_parameter(Name=f"{CONTROL_PREFIX}/config-bucket")["Parameter"]["Value"]
    except (BotoCoreError, ClientError) as exc:
        raise RuntimeError(
            "Control plane not found. Deploy StrmBank-Control from this UI first.",
        ) from exc


def load_prefix_params(prefix: str, region: str) -> dict[str, str]:
    ssm = session(region).client("ssm")
    path = prefix if prefix.startswith("/") else f"/{prefix}"
    paginator = ssm.get_paginator("get_parameters_by_path")
    values: dict[str, str] = {}
    try:
        for page in paginator.paginate(Path=path, Recursive=True, WithDecryption=True):
            for parameter in page.get("Parameters", []):
                name = parameter["Name"].rsplit("/", 1)[-1]
                values[name] = parameter["Value"]
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in {"ParameterNotFound", "AccessDeniedException"}:
            return {}
        raise RuntimeError(f"Unable to read SSM path {path}: {exc}") from exc
    except BotoCoreError as exc:
        raise RuntimeError(f"Unable to read SSM path {path}: {exc}") from exc
    return values


def list_tagged_resources(region: str, env_prefix: str) -> list[dict[str, str]]:
    client = session(region).client("resourcegroupstaggingapi")
    paginator = client.get_paginator("get_resources")
    rows: list[dict[str, str]] = []
    try:
        for page in paginator.paginate(
            TagFilters=[
                {"Key": "Project", "Values": [PROJECT]},
                {"Key": "EnvPrefix", "Values": [env_prefix]},
            ],
        ):
            for mapping in page.get("ResourceTagMappingList", []):
                tags = {tag["Key"]: tag["Value"] for tag in mapping.get("Tags", [])}
                rows.append(
                    {
                        "arn": mapping.get("ResourceARN", ""),
                        "environment": tags.get("Environment", ""),
                        "prefix": tags.get("EnvPrefix", ""),
                        "role": tags.get("Role", ""),
                    },
                )
    except (BotoCoreError, ClientError) as exc:
        raise RuntimeError(f"Unable to list tagged resources: {exc}") from exc
    return rows
