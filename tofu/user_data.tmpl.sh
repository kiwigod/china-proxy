#!/bin/sh
# Lightsail user_data: runs ONLY on first boot. Config changes after creation
# MUST go through scripts/redeploy.sh over SSH, never by editing running files
# or by expecting `tofu apply` to re-run this script.
# POSIX sh ONLY: Lightsail executes this with dash (/bin/sh), ignoring the
# shebang — no bashisms (no pipefail, [[ ]], arrays). Keep it that way.
set -eu

# Docker from Ubuntu repos; compose as a pinned upstream binary because
# noble's repos ship no docker-compose-plugin. Versioned download, not a
# curl-piped installer; nothing built on the VPS.
# v5.5.1 verified 2026-09-27: latest stable, asset exists. Literal here, not
# a templatefile var — main.tf passes nothing for it, and tofu validate does
# not catch missing template vars (only apply-time templatefile does).
apt-get update
apt-get install -y docker.io curl ca-certificates
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
systemctl enable --now docker
usermod -aG docker ubuntu # Hermes/redeploy SSH runs as ubuntu, not root

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
