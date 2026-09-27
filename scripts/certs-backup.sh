#!/bin/bash
# VPS -> local: archive the hysteria-certs Docker volume (ACME account +
# certificates) into $CERT_STORE/hysteria-certs.tgz, so rebuilds and wakes
# resume from cache without asking Let's Encrypt for a new certificate.
# Run before every destroy; sleep.sh does this automatically.
# Hermes-local store keeps the bundle off extra AWS services; the VPS never
# sees S3 and needs no IAM (Lightsail has no instance profiles anyway).
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
mkdir -p "$CERT_STORE"
chmod 700 "$CERT_STORE"

IP="$(tofu -chdir=tofu output -raw static_ip)"
KEY="${SSH_KEY:-$HOME/.ssh/china-proxy.pem}"
[ -f "$KEY" ] || { echo "SSH key not found: $KEY (set SSH_KEY=...)" >&2; exit 1; }
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"

VOLMP="$($SSH "docker volume ls -q | grep hysteria-certs | head -n 1 | xargs docker volume inspect -f '{{.Mountpoint}}'")"
[ -n "$VOLMP" ] || { echo "no hysteria-certs volume on $IP (fresh box?)" >&2; exit 1; }

BUNDLE="$CERT_STORE/hysteria-certs.tgz"
TMP_BUNDLE="$BUNDLE.tmp.$$"
trap 'rm -f "$TMP_BUNDLE"' EXIT
$SSH "sudo tar cz -C '$VOLMP' ." > "$TMP_BUNDLE"

# Prove the bundle holds a live leaf cert (grep-no-match guarded for pipefail)
# BEFORE replacing any previous good bundle.
CRT="$(tar tzf "$TMP_BUNDLE" | grep '\.crt$' | head -n 1 || true)"
[ -n "$CRT" ] || { echo "archive has no certificate (ACME never completed on this host?)" >&2; exit 1; }
EXPIRY="$(tar xzf "$TMP_BUNDLE" -O "$CRT" | openssl x509 -enddate -noout)"
chmod 600 "$TMP_BUNDLE"
mv "$TMP_BUNDLE" "$BUNDLE"
trap - EXIT
echo "backed up $DOMAIN cert bundle -> $BUNDLE ($EXPIRY)"
