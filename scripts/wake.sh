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

tofu -chdir=tofu apply -var-file=tofu.tfvars -auto-approve "$@"
# The key pair is Tofu-managed: every apply-after-destroy creates NEW key
# material, so the saved .pem is stale until re-exported (all SSH below
# uses $KEY — without this, wake always fails auth). Atomic write: a
# concurrent/interrupted writer must never leave a truncated key behind
# (sshd fails closed on those with a libcrypto error).
mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"
TMP_KEY="$KEY.tmp.$$"
trap 'rm -f "$TMP_KEY"' EXIT
tofu -chdir=tofu output -raw ssh_private_key_pem > "$TMP_KEY" && chmod 600 "$TMP_KEY" && mv "$TMP_KEY" "$KEY"
trap - EXIT
IP="$(tofu -chdir=tofu output -raw static_ip)"

# Recycled cloud IPs: drop any stale host key, re-establish trust on connect.
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"

# First boot runs apt + pull + xray start (~3-6 min). Hysteria is NOT started
# by user_data (an empty volume would fire a doomed ACME order) — it starts
# below, after the cert decision.
deadline=$((SECONDS + 600))
while [ "$SECONDS" -lt "$deadline" ]; do
  UP="$($SSH 'docker compose -f /opt/proxy/docker-compose.yml ps --format "{{.Service}}={{.State}}" 2>/dev/null' || true)"
  if echo "$UP" | grep -qx 'xray=running'; then
    echo "xray running (first boot done)"
    break
  fi
  sleep 15
done
echo "$UP" | grep -qx 'xray=running' || { echo "xray never came Up (check cloud-init on $IP)" >&2; exit 1; }

# Stage hysteria without starting it: creates the volume + container, so the
# cert decision below lands before the first process start — no doomed order.
$SSH 'docker compose -f /opt/proxy/docker-compose.yml create hysteria'

if [ -f "$CERT_STORE/hysteria-certs.tgz" ]; then
  ./scripts/certs-restore.sh
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" ./scripts/setup-dns.sh --skip-acme-check
else
  echo "no cert bundle — start empty, then fresh issuance path"
  $SSH 'docker compose -f /opt/proxy/docker-compose.yml up -d hysteria'
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" ./scripts/setup-dns.sh
fi
echo "awake: $DOMAIN -> $IP. NEXT: egress-test both outbounds (HERMES.md §8)."
