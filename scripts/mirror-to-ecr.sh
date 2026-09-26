#!/bin/bash
# Fallback ONLY: mirror the prebuilt upstream images verbatim into ECR
# (same region as the instance) in case Docker Hub / ghcr.io pulls fail from
# the VPS. Nothing is built: pull, re-tag, push. After this, set
# xray_image/hy2_image to the printed ECR URIs; no compose or user_data change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v aws >/dev/null 2>&1 || { echo "missing dependency: aws" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "missing dependency: docker" >&2; exit 1; }

REGION="${AWS_REGION:-ap-southeast-1}"
XRAY_UPSTREAM="$(python3 -c "
import re;
print(re.search(r'variable \"xray_image\".*?default\s*=\s*\"([^\"]+)\"', open('tofu/variables.tf').read(), re.S).group(1))")"
HY2_UPSTREAM="$(python3 -c "
import re;
print(re.search(r'variable \"hy2_image\".*?default\s*=\s*\"([^\"]+)\"', open('tofu/variables.tf').read(), re.S).group(1))")"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text --region "$REGION")"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

mirror() {
  local upstream="$1" repo="$2" tag="${1##*:}"
  aws ecr create-repository --repository-name "china-proxy/$repo" --region "$REGION" >/dev/null 2>&1 \
    || true # ignore-exists: idempotent
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR" >/dev/null
  docker pull "$upstream"
  docker tag "$upstream" "$ECR/china-proxy/$repo:$tag"
  docker push "$ECR/china-proxy/$repo:$tag"
  echo "$repo: $ECR/china-proxy/$repo:$tag"
}

mirror "$XRAY_UPSTREAM" xray
mirror "$HY2_UPSTREAM" hysteria

echo "To switch: set xray_image/hy2_image to the URIs above (tofu.tfvars or variable defaults)."
