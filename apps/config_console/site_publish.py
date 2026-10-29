from __future__ import annotations

import json
import mimetypes
import time
from pathlib import Path

from aws_env import session

REPO_ROOT = Path(__file__).resolve().parents[2]
WEB_DIR = REPO_ROOT / "web"


def cognito_hosted_domain(prefix: str, region: str) -> str:
    slug = f"{prefix.replace('_', '')}auth"[:63]
    return f"https://{slug}.auth.{region}.amazoncognito.com"


def build_site_config(outputs: dict[str, str]) -> dict[str, str]:
    region = outputs["region"]
    prefix = outputs["prefix"]
    web_domain = outputs["web-domain"]
    origin = f"https://{web_domain}"
    return {
        "region": region,
        "userPoolId": outputs["user-pool-id"],
        "clientId": outputs["user-pool-client-id"],
        "identityPoolId": outputs.get("identity-pool-id", ""),
        "cognitoDomain": cognito_hosted_domain(prefix, region),
        "redirectUri": f"{origin}/callback",
        "logoutUri": f"{origin}/",
        "websiteBucket": outputs["website-bucket"],
        "webUrl": origin,
        "apiUrl": outputs.get("api-url", ""),
    }


def distribution_id(region: str, web_domain: str) -> str:
    client = session(region).client("cloudfront")
    paginator = client.get_paginator("list_distributions")
    for page in paginator.paginate():
        for item in page.get("DistributionList", {}).get("Items", []):
            if item.get("DomainName") == web_domain:
                return item["Id"]
    raise RuntimeError(f"No CloudFront distribution found for {web_domain}")


def publish_frontend(outputs: dict[str, str], region: str) -> dict[str, str]:
    cfg = build_site_config(outputs)
    bucket = outputs["website-bucket"]
    s3 = session(region).client("s3")
    uploaded: list[str] = []
    for path in WEB_DIR.rglob("*"):
        if not path.is_file() or path.name in {"config.js", "preview.html", "preview.js"}:
            continue
        key = path.relative_to(WEB_DIR).as_posix()
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=path.read_bytes(),
            ContentType=content_type,
            CacheControl="no-cache" if path.suffix in {".html", ".js"} else "public, max-age=86400",
        )
        uploaded.append(key)
    s3.put_object(
        Bucket=bucket,
        Key="config.js",
        Body=f"window.STRM_CONFIG = {json.dumps(cfg, indent=2)};\n".encode("utf-8"),
        ContentType="application/javascript",
        CacheControl="no-cache",
    )
    uploaded.append("config.js")
    dist_id = distribution_id(region, outputs["web-domain"])
    cf = session(region).client("cloudfront")
    invalidation = cf.create_invalidation(
        DistributionId=dist_id,
        InvalidationBatch={
            "CallerReference": f"strm-{int(time.time_ns())}",
            "Paths": {"Quantity": 1, "Items": ["/*"]},
        },
    )
    return {
        "webUrl": cfg["webUrl"],
        "uploaded": ", ".join(uploaded),
        "invalidation": invalidation["Invalidation"]["Id"],
        "cognitoDomain": cfg["cognitoDomain"],
    }
