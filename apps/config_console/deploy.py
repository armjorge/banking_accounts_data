from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INFRA_DIR = REPO_ROOT / "infra"

LineCallback = Callable[[str], None]


def run_cdk(
    args: list[str],
    *,
    account: str | None = None,
    region: str | None = None,
    timeout: int = 1800,
    on_line: LineCallback | None = None,
) -> tuple[int, str]:
    env = os.environ.copy()
    env["CI"] = "1"
    env["CDK_DISABLE_CLI_TELEMETRY"] = "1"
    if account:
        env["CDK_DEFAULT_ACCOUNT"] = account
    if region:
        env["CDK_DEFAULT_REGION"] = region
        env.setdefault("AWS_REGION", region)
        env.setdefault("AWS_DEFAULT_REGION", region)

    command = ["npx", "cdk", *args]
    if args and args[0] == "deploy" and "--progress" not in args:
        command = ["npx", "cdk", "deploy", "--progress", "events", *args[1:]]

    proc = subprocess.Popen(
        command,
        cwd=INFRA_DIR,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    lines: list[str] = []
    try:
        for line in proc.stdout:
            lines.append(line)
            sys.stdout.write(line)
            sys.stdout.flush()
            if on_line:
                on_line(line)
        returncode = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        returncode = 124
        lines.append("\nCDK timed out.\n")
    return returncode, "".join(lines).strip()


def deploy_control_plane(
    *,
    account: str | None = None,
    region: str | None = None,
    on_line: LineCallback | None = None,
) -> tuple[int, str]:
    return run_cdk(
        ["deploy", "StrmBank-Control", "--require-approval", "never"],
        account=account,
        region=region,
        on_line=on_line,
    )


def deploy_environment(
    environment_name: str,
    prefix: str,
    *,
    account: str | None = None,
    region: str | None = None,
    on_line: LineCallback | None = None,
) -> tuple[int, str, dict[str, str]]:
    outputs_file = INFRA_DIR / "cdk.out" / f"{environment_name}.outputs.json"
    outputs_file.parent.mkdir(parents=True, exist_ok=True)
    code, log = run_cdk(
        [
            "deploy",
            "StrmBank-Control",
            f"StrmBank-{environment_name}",
            "--require-approval",
            "never",
            "--context",
            f"environment={environment_name}",
            "--context",
            f"prefix={prefix}",
            "--outputs-file",
            str(outputs_file),
        ],
        account=account,
        region=region,
        on_line=on_line,
    )
    outputs: dict[str, str] = {}
    if outputs_file.exists():
        raw = json.loads(outputs_file.read_text(encoding="utf-8"))
        stack = raw.get(f"StrmBank-{environment_name}") or {}
        outputs = {str(key): str(value) for key, value in stack.items()}
    return code, log, outputs
