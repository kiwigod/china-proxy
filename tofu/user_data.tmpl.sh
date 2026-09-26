#!/bin/bash
# Lightsail user_data: runs ONLY on first boot. Config changes after creation
# MUST go through scripts/redeploy.sh over SSH, never by editing running files
# or by expecting `tofu apply` to re-run this script.
set -euo pipefail

# Ubuntu repo packages only; no curl-piped installers, nothing built on the VPS.
apt-get update
apt-get install -y docker.io docker-compose-plugin
systemctl enable --now docker

# Lightsail firewall is authoritative; a host firewall must not block us.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw disable
fi

mkdir -p /opt/proxy/xray /opt/proxy/hysteria

# Rendered blobs are baked in by tofu (templatefile in main.tf); no git clone,
# no secret fetching on the VPS. Quoted heredocs: no shell expansion.
cat > /opt/proxy/docker-compose.yml <<'__PROXY_COMPOSE_EOF__'
${compose_yaml}
__PROXY_COMPOSE_EOF__

cat > /opt/proxy/xray/config.json <<'__PROXY_XRAY_EOF__'
${xray_config}
__PROXY_XRAY_EOF__

cat > /opt/proxy/hysteria/config.yaml <<'__PROXY_HYSTERIA_EOF__'
${hysteria_config}
__PROXY_HYSTERIA_EOF__

# Idempotent on re-execution via SSH (overwrite + pull/up -d).
docker compose -f /opt/proxy/docker-compose.yml pull
docker compose -f /opt/proxy/docker-compose.yml up -d
