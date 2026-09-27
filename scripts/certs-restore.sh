#!/bin/bash
# Local -> VPS: unpack $CERT_STORE/hysteria-certs.tgz into the hysteria-certs
# Docker volume and restart hysteria. Certmagic resumes from cache, so no
# Let's Encrypt issuance happens (dodge the ~5 duplicate/week limit across
# rebuilds and wakes). Ownership round-trips: tar preserves the numeric
# uid/gid the same image wrote, restored as root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for dep in ssh tar openssl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done
command -v tofu >/dev/null 2>&1 || { echo "missing dependency: tofu" >&2; exit 1; }

DOMAIN="$(python3 -c "
import re;
print(re.search(r'domain_name\s*=\s*\"([^\"]+)\"', open('tofu/tofu.tfvars').read()).group(1))")"
CERT_STORE="${CERT_STORE:-$HOME/.china-proxy/certs/$DOMAIN}"
BUNDLE="$CERT_STORE/hysteria-certs.tgz"
[ -f "$BUNDLE" ] || { echo "no bundle at $BUNDLE (fresh domain? provision with setup-dns.sh issuance instead)" >&2; exit 1; }

CRT="$(tar tzf "$BUNDLE" | grep '\.crt$' | head -n 1 || true)"
[ -n "$CRT" ] || { echo "bundle has no certificate" >&2; exit 1; }
EXPIRY="$(tar xzf "$BUNDLE" -O "$CRT" | openssl x509 -enddate -noout)"
echo "restoring $DOMAIN bundle ($EXPIRY)"

IP="$(tofu -chdir=tofu output -raw static_ip)"
KEY="${SSH_KEY:-$HOME/.ssh/china-proxy.pem}"
[ -f "$KEY" ] || { echo "SSH key not found: $KEY (set SSH_KEY=...)" >&2; exit 1; }
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"

VOLMP="$($SSH "docker volume ls -q | grep hysteria-certs | head -n 1 | xargs docker volume inspect -f '{{.Mountpoint}}'")"
[ -n "$VOLMP" ] || { echo "no hysteria-certs volume on $IP (wait for first boot?)" >&2; exit 1; }

cat "$BUNDLE" | $SSH "sudo tar xz -C '$VOLMP' ."
$SSH 'docker restart hysteria && docker ps --format "{{.Names}} {{.Status}}" | grep -E "^(xray|hysteria) "'
