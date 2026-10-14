#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

if ! command -v aws >/dev/null; then
  echo "aws CLI is required. Install it, then run: aws login" >&2
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [[ -z "${ACCOUNT}" || "${ACCOUNT}" == "None" ]]; then
  echo "Could not read the AWS account. Run aws login in this terminal, then retry." >&2
  exit 1
fi

echo "Bootstrapping aws://${ACCOUNT}/${REGION}"
cd "${ROOT}/infra"
npx cdk bootstrap "aws://${ACCOUNT}/${REGION}"
