#!/bin/bash
# Hermes "going to bed": back up the cert bundle (best-effort), then destroy
# everything billable. Stopped instances still bill — only deletion stops the
# meter — and orphaned static IPs bill $0.005/hr, so destroy takes both.
# DNS record stays (stale target fails closed; avoids negative-cache quirks).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v tofu >/dev/null 2>&1 || { echo "missing dependency: tofu" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "missing dependency: aws" >&2; exit 1; }

INST="${INSTANCE_NAME:-china-proxy}" # matches instance_name default; static IP is "${INST}-ip"
REGION="${AWS_REGION:-ap-southeast-1}"
AWS_AZ="${AWS_AZ:-${REGION}a}" # valid in every standard region; override per move/capacity
REGION_VARS=(-var="aws_region=$REGION" -var="az=$AWS_AZ")
echo "targeting $REGION / $AWS_AZ" >&2
LOCKFILE="$ROOT/tofu/.asleep"

./scripts/certs-backup.sh \
  || echo "WARNING: cert backup failed — wake will issue a fresh certificate"

tofu -chdir=tofu destroy -var-file=tofu.tfvars -auto-approve "${REGION_VARS[@]}"

if aws lightsail get-instance --instance-name "$INST" --region "$REGION" >/dev/null 2>&1; then
  echo "instance $INST still exists" >&2
  exit 1
fi
if aws lightsail get-static-ip --static-ip-name "$INST-ip" --region "$REGION" >/dev/null 2>&1; then
  echo "static IP $INST-ip still allocated (it bills while unattached)" >&2
  exit 1
fi
echo "asleep: no instances, no static IPs; billing stopped."
DOMAIN="$(python3 -c "
import re;
print(re.search(r'domain_name\s*=\s*\"([^\"]+)\"', open('tofu/tofu.tfvars').read()).group(1))")"
CERT_STORE="${CERT_STORE:-$HOME/.china-proxy/certs/$DOMAIN}"
{
  echo "asleep_at=$(date -u +%FT%TZ)"
  if [ -f "$CERT_STORE/hysteria-certs.tgz" ]; then echo "cert_bundle=present"; else echo "cert_bundle=absent"; fi
} > "$LOCKFILE"
chmod 600 "$LOCKFILE"
echo "sleep lock written: $LOCKFILE"
