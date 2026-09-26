#!/bin/bash
# Generates all secrets on the Mac (never on the VPS), writes tofu.tfvars and
# clients/sing-box.json, prints the two client share links.
#
# Single source of truth for image tags and REALITY params: tofu/variables.tf
# defaults (parsed below). Connection params must match the server there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for dep in openssl uuidgen docker python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done

# --- xray image + REALITY client params from tofu/variables.tf defaults ---
XRAY_IMAGE="$(python3 -c "
import re;
src = open('tofu/variables.tf').read();
def default(name):
    m = re.search(r'variable \"%s\".*?default\s*=\s*\"([^\"]+)\"' % name, src, re.S);
    return m.group(1);
print(default('xray_image'))")"
REALITY_SNI="$(python3 -c "
import re;
src = open('tofu/variables.tf').read();
m = re.search(r'variable \"reality_server_name\".*?default\s*=\s*\"([^\"]+)\"', src, re.S);
print(m.group(1))")"
REALITY_FP="$(python3 -c "
import re;
src = open('tofu/variables.tf').read();
m = re.search(r'variable \"reality_fingerprint\".*?default\s*=\s*\"([^\"]+)\"', src, re.S);
print(m.group(1))")"

# --- prompts (never committed) ---
while [ -z "${DOMAIN_NAME:-}" ]; do read -rp "domain_name (e.g. proxy.example.com): " DOMAIN_NAME; done
while [ -z "${ACME_EMAIL:-}" ]; do read -rp "acme_email: " ACME_EMAIL; done
case "$DOMAIN_NAME" in *.*) ;; *) echo "domain_name looks wrong: $DOMAIN_NAME" >&2; exit 1;; esac

mkdir -p secrets clients
chmod 700 secrets

# --- secrets ---
if command -v uuidgen >/dev/null 2>&1; then
  uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\n' > secrets/xray_uuid
else
  python3 -c "import uuid; print(uuid.uuid4(), end='')" > secrets/xray_uuid
fi
openssl rand -hex 4 | tr -d '\n' > secrets/reality_short_id
python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)), end='')" > secrets/hy2_password
echo >&2 "generating REALITY keypair with $XRAY_IMAGE ..."
X25519_OUT="$(docker run --rm "$XRAY_IMAGE" x25519)"
echo "$X25519_OUT" | awk '/PrivateKey/{print $NF}' | tr -d '\r\n' > secrets/reality_private_key
echo "$X25519_OUT" | awk '/PublicKey/{print $NF}' | tr -d '\r\n' > secrets/reality_public_key
chmod 600 secrets/*
[ -s secrets/reality_private_key ] && [ -s secrets/reality_public_key ] \
  || { echo "REALITY keypair generation failed" >&2; exit 1; }

XRAY_UUID="$(cat secrets/xray_uuid)"
SHORT_ID="$(cat secrets/reality_short_id)"
HY2_PASSWORD="$(cat secrets/hy2_password)"
RE_REALITY_PUB="$(cat secrets/reality_public_key)"

# --- tofu.tfvars (gitignored, chmod 600) ---
cat > tofu/tofu.tfvars <<EOF
domain_name         = "$DOMAIN_NAME"
acme_email          = "$ACME_EMAIL"
xray_uuid           = "$XRAY_UUID"
reality_private_key = "$(cat secrets/reality_private_key)"
reality_short_id    = "$SHORT_ID"
hy2_password        = "$HY2_PASSWORD"
EOF
chmod 600 tofu/tofu.tfvars

# --- sing-box client config (one-click import for Hiddify/Streisand/v2rayNG/NekoBox) ---
DOMAIN_NAME="$DOMAIN_NAME" XRAY_UUID="$XRAY_UUID" SHORT_ID="$SHORT_ID" \
HY2_PASSWORD="$HY2_PASSWORD" REALITY_PUB="$RE_REALITY_PUB" REALITY_SNI="$REALITY_SNI" \
REALITY_FP="$REALITY_FP" python3 - <<'PYEOF'
import json, os
e = os.environ
cfg = {
    "log": {"level": "info"},
    "outbounds": [
        {"type": "vless", "tag": "china-xray",
         "server": e["DOMAIN_NAME"], "server_port": 443,
         "uuid": e["XRAY_UUID"], "flow": "xtls-rprx-vision", "network": "tcp",
         "tls": {"enabled": True, "server_name": e["REALITY_SNI"],
                 "utls": {"enabled": True, "fingerprint": e["REALITY_FP"]},
                 "reality": {"enabled": True, "public_key": e["REALITY_PUB"],
                             "short_id": e["SHORT_ID"]}}},
        {"type": "hysteria2", "tag": "china-hy2",
         "server": e["DOMAIN_NAME"], "server_port": 443,
         "password": e["HY2_PASSWORD"],
         "tls": {"enabled": True, "server_name": e["DOMAIN_NAME"], "alpn": ["h3"]}},
        {"type": "urltest", "tag": "china-auto",
         "outbounds": ["china-xray", "china-hy2"],
         "url": "https://www.gstatic.com/generate_204", "interval": "10m"},
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ],
    "route": {
        "rule_set": [
            {"type": "remote", "tag": "geoip-private", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-private.srs",
             "download_detour": "direct"},
            {"type": "remote", "tag": "geosite-cn", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
             "download_detour": "direct"},
        ],
        "rules": [
            {"rule_set": "geoip-private", "outbound": "direct"},
            {"rule_set": "geosite-cn", "outbound": "direct"},
        ],
        "final": "china-auto",
        "auto_detect_interface": True,
    },
}
open("clients/sing-box.json", "w").write(json.dumps(cfg, indent=2) + "\n")
PYEOF

VLESS_LINK="vless://${XRAY_UUID}@${DOMAIN_NAME}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FP}&pbk=${RE_REALITY_PUB}&sid=${SHORT_ID}&type=tcp#china-xray"
HY2_LINK="hy2://${HY2_PASSWORD}@${DOMAIN_NAME}:443/?sni=${DOMAIN_NAME}&alpn=h3&insecure=0#china-hy2"
echo "$VLESS_LINK" > clients/xray-link.txt
echo "$HY2_LINK" > clients/hy2-link.txt

echo
echo "secrets/ + tofu/tofu.tfvars + clients/sing-box.json written."
echo
echo "Xray:     $VLESS_LINK"
echo "Hysteria: $HY2_LINK"
echo
echo "NOTE: links use the domain, so they work once DNS propagates. Before that,"
echo "replace the host with the static IP (Xray works immediately via IP)."
echo "NEXT: cd tofu && tofu init && tofu plan -var-file=tofu.tfvars -out=tfplan"
