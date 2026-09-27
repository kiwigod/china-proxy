#!/bin/bash
# The ONLY supported config-update path. Lightsail user_data runs only on
# first boot, so `tofu apply` never refreshes the running configs; this script
# re-renders docker/* templates locally and pushes them over SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for dep in ssh scp python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done

IP="$(tofu -chdir=tofu output -raw static_ip)"
KEY="${SSH_KEY:-$HOME/.ssh/china-proxy.pem}"
[ -f "$KEY" ] || { echo "SSH key not found: $KEY (set SSH_KEY=...)" >&2; exit 1; }
SSH="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new ubuntu@$IP"

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

# Render with the same inputs tofu uses: secrets/* + tofu.tfvars + variables.tf.
python3 - "$RENDER_DIR" <<'PYEOF'
import os, re, sys
out = sys.argv[1]
varsrc = open('tofu/variables.tf').read()
tfvars = open('tofu/tofu.tfvars').read()
sec = lambda n: open('secrets/%s' % n).read().strip()
def vardefault(name):
    return re.search(r'variable "%s".*?default\s*=\s*"([^"]+)"' % name, varsrc, re.S).group(1)
def tfvar(name):
    return re.search(r'%s\s*=\s*"([^"]+)"' % name, tfvars).group(1)
subs = {
    'xray_image': vardefault('xray_image'),
    'hy2_image': vardefault('hy2_image'),
    'xray_uuid': sec('xray_uuid'),
    'reality_private_key': sec('reality_private_key'),
    'reality_short_id': sec('reality_short_id'),
    'reality_dest': vardefault('reality_dest'),
    'reality_server_name': vardefault('reality_server_name'),
    'domain_name': tfvar('domain_name'),
    'acme_email': tfvar('acme_email'),
    'hy2_password': sec('hy2_password'),
}
def render(tmpl):
    return re.sub(r'\$\{(\w+)\}', lambda m: subs[m.group(1)], tmpl)
jobs = [('docker/compose.yml', 'docker-compose.yml'),
        ('docker/xray/config.json.tmpl', 'xray-config.json'),
        ('docker/hysteria/config.yaml.tmpl', 'hysteria-config.yaml')]
for src, dst in jobs:
    open(os.path.join(out, dst), 'w').write(render(open(src).read()))
print('rendered: %s' % ', '.join(d for _, d in jobs))
PYEOF

scp -i "$KEY" -o StrictHostKeyChecking=accept-new \
  "$RENDER_DIR/docker-compose.yml" "ubuntu@$IP:/tmp/docker-compose.yml"
scp -i "$KEY" -o StrictHostKeyChecking=accept-new \
  "$RENDER_DIR/xray-config.json" "ubuntu@$IP:/tmp/config.json"
scp -i "$KEY" -o StrictHostKeyChecking=accept-new \
  "$RENDER_DIR/hysteria-config.yaml" "ubuntu@$IP:/tmp/config.yaml"

# shellcheck disable=SC2087
$SSH 'sudo mkdir -p /opt/proxy/xray /opt/proxy/hysteria &&
      sudo install -m 644 /tmp/docker-compose.yml /opt/proxy/docker-compose.yml &&
      sudo install -m 600 /tmp/config.json /opt/proxy/xray/config.json &&
      sudo install -m 600 /tmp/config.yaml /opt/proxy/hysteria/config.yaml &&
      rm /tmp/docker-compose.yml /tmp/config.json /tmp/config.yaml &&
      docker compose -f /opt/proxy/docker-compose.yml pull &&
      docker compose -f /opt/proxy/docker-compose.yml up -d &&
      docker ps --format "{{.Names}} {{.Status}}"'
