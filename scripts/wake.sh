#!/bin/bash
# Hermes "wake up": apply -> wait for first boot -> restore certs (or fresh
# issuance when no bundle exists) -> DNS update + propagation wait.
# Extra args pass through to tofu apply (e.g. -var='aws_region=ap-northeast-1'
# -var='az=ap-northeast-1a' for a region move). Expect ~5-10 min total.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for dep in ssh ssh-keygen dig; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done
command -v tofu >/dev/null 2>&1 || { echo "missing dependency: tofu" >&2; exit 1; }

DOMAIN="$(python3 -c "
import re;
print(re.search(r'domain_name\s*=\s*\"([^\"]+)\"', open('tofu/tofu.tfvars').read()).group(1))")"
CERT_STORE="${CERT_STORE:-$HOME/.china-proxy/certs/$DOMAIN}"
KEY="${SSH_KEY:-$HOME/.ssh/china-proxy.pem}"
[ -f "$KEY" ] || { echo "SSH key not found: $KEY (set SSH_KEY=...)" >&2; exit 1; }

tofu -chdir=tofu apply -var-file=tofu.tfvars -auto-approve "$@"
IP="$(tofu -chdir=tofu output -raw static_ip)"

# Recycled cloud IPs: drop any stale host key, re-establish trust on connect.
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"

# First boot runs apt + pull + compose up concurrently (~3-6 min).
deadline=$((SECONDS + 600))
while [ "$SECONDS" -lt "$deadline" ]; do
  UP="$($SSH 'docker ps --format "{{.Names}}"' 2>/dev/null || true)"
  if echo "$UP" | grep -qx xray && echo "$UP" | grep -qx hysteria; then
    echo "both services Up"
    break
  fi
  sleep 15
done
echo "$UP" | grep -qx xray || { echo "xray never came Up (check cloud-init on $IP)" >&2; exit 1; }
echo "$UP" | grep -qx hysteria || { echo "hysteria never came Up (check cloud-init on $IP)" >&2; exit 1; }

if [ -f "$CERT_STORE/hysteria-certs.tgz" ]; then
  ./scripts/certs-restore.sh
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" ./scripts/setup-dns.sh --skip-acme-check
else
  echo "no cert bundle — fresh issuance path"
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" ./scripts/setup-dns.sh
fi
echo "awake: $DOMAIN -> $IP. NEXT: egress-test both outbounds (HERMES.md §8)."
