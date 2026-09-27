#!/bin/bash
# Automates README steps 3-5: Cloudflare DNS A record (DNS-only),
# propagation wait, and Hysteria ACME confirmation.
#
# Needs: CLOUDFLARE_API_TOKEN env (Cloudflare dashboard -> My Profile ->
# API Tokens -> "Edit zone DNS" template, scoped to your zone). The token is
# never written anywhere; pass it in the environment each run.
# `--skip-acme-check` (wake path): DNS update + propagation wait only, then a
# container-health check instead of issuance watch (cert was injected).
#
# Domain comes from tofu/tofu.tfvars, IP from `tofu output -raw static_ip`.
SKIP_ACME=0
for _arg in "$@"; do
  case "$_arg" in
    --skip-acme-check) SKIP_ACME=1 ;;
    *) echo "unknown arg: $_arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

for dep in curl python3 dig ssh; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done
command -v tofu >/dev/null 2>&1 || { echo "missing dependency: tofu" >&2; exit 1; }
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (see header comment)}"

DOMAIN="$(python3 -c "
import re;
print(re.search(r'domain_name\s*=\s*\"([^\"]+)\"', open('tofu/tofu.tfvars').read()).group(1))")"
IP="$(tofu -chdir=tofu output -raw static_ip)"
CF_API="https://api.cloudflare.com/client/v4"
AUTH="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

cf() { # cf METHOD PATH [BODY_FILE] -> response body on stdout, exits 1 on API error
  local method="$1" path="$2" body="${3:-}" resp
  if [ -n "$body" ]; then
    resp="$(curl -sS -X "$method" -H "$AUTH" -H 'Content-Type: application/json' \
      --data @"$body" "$CF_API$path")"
  else
    resp="$(curl -sS -X "$method" -H "$AUTH" "$CF_API$path")"
  fi
  CLOUDFLARE_RESP="$resp" python3 -c "
import json, os, sys;
r = json.loads(os.environ['CLOUDFLARE_RESP']);
if not r.get('success'):
    print('Cloudflare API error: %s' % json.dumps(r.get('errors')), file=sys.stderr);
    sys.exit(1);
print(json.dumps(r.get('result')))"
}

# --- 1. zone (CF_ZONE_ID or longest zone name that suffix-matches the domain) ---
if [ -z "${CF_ZONE_ID:-}" ]; then
  CF_ZONE_ID="$(DOMAIN="$DOMAIN" cf GET '/zones?per_page=50' | DOMAIN="$DOMAIN" python3 -c "
import json, os, sys;
zones = json.load(sys.stdin);
dom = os.environ['DOMAIN'].lower().rstrip('.');
best = '';
for z in zones:
    n = z['name'].lower();
    if dom == n or dom.endswith('.' + n):
        if len(n) > len(best): best = n;
match = [z['id'] for z in zones if z['name'].lower() == best];
sys.exit('no Cloudflare zone matches %s' % dom) if not match else print(match[0])")"
fi
echo "zone: $CF_ZONE_ID  domain: $DOMAIN  ip: $IP"

# --- 2. A record, DNS-only (proxied=false is the whole point) ---
REC_JSON="$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=A&name=$DOMAIN")"
REC_ID="$(echo "$REC_JSON" | python3 -c "
import json, sys;
r = json.load(sys.stdin);
print(r[0]['id'] if r else '')")"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
python3 -c "
import json;
print(json.dumps({'type': 'A', 'name': '$DOMAIN', 'content': '$IP', 'ttl': 1, 'proxied': False}))" > "$BODY"
if [ -n "$REC_ID" ]; then
  cf PUT "/zones/$CF_ZONE_ID/dns_records/$REC_ID" "$BODY" >/dev/null
  echo "updated A $DOMAIN -> $IP (DNS-only)"
else
  cf POST "/zones/$CF_ZONE_ID/dns_records" "$BODY" >/dev/null
  echo "created A $DOMAIN -> $IP (DNS-only)"
fi

# --- 3. propagation wait (Cloudflare resolver, then system default) ---
deadline=$((SECONDS + ${DNS_WAIT_MAX:-900}))
while [ "$SECONDS" -lt "$deadline" ]; do
  if dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | grep -qx "$IP" \
  || dig +short "$DOMAIN" 2>/dev/null | grep -qx "$IP"; then
    echo "DNS resolves: $DOMAIN -> $IP"
    break
  fi
  sleep 10
done
dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | grep -qx "$IP" \
  || { echo "timed out waiting for DNS propagation" >&2; exit 1; }

KEY="${SSH_KEY:-$HOME/.ssh/china-proxy.pem}"
[ -f "$KEY" ] || { echo "SSH key not found: $KEY (set SSH_KEY=...)" >&2; exit 1; }
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"
if [ "$SKIP_ACME" = 1 ]; then
  # Wake-with-injected-cert: no issuance will appear in logs. Health-check
  # instead (bundle presence + expiry were verified by certs-restore.sh).
  UP="$($SSH 'docker ps --format "{{.Names}} {{.Status}}"' || true)"
  echo "$UP" | grep -q '^hysteria Up' \
    || { printf 'hysteria not Up:\n%s\n' "$UP" >&2; exit 1; }
  echo "$UP" | grep -q '^xray Up' || echo "WARNING: xray not Up" >&2
  echo "DNS resolves; injected cert in place; confirm with an egress test."
  exit 0
fi
deadline=$((SECONDS + ${ACME_WAIT_MAX:-600}))
while [ "$SECONDS" -lt "$deadline" ]; do
  LOGS="$($SSH 'docker logs hysteria 2>&1 | tail -20' || true)"
  if echo "$LOGS" | grep -qiE 'FATAL|invalid config'; then
    echo "$LOGS" >&2
    echo "hysteria config rejected (see above)" >&2
    exit 1
  fi
  if echo "$LOGS" | grep -qiE 'certificat.*obtained|obtained.*certificat'; then
    echo "Hysteria holds a certificate for $DOMAIN"
    $SSH 'docker ps --format "{{.Names}} {{.Status}}"' | grep -E '^(xray|hysteria) ' || true
    echo "NEXT: import clients/sing-box.json (or the share links) and force the china-hy2 outbound to test."
    exit 0
  fi
  sleep 15
done
echo "timed out waiting for ACME issuance; recent hysteria logs:" >&2
$SSH 'docker logs hysteria 2>&1 | tail -20' >&2 || true
exit 1
