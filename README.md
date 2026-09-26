# china-proxy

One Lightsail VPS in Singapore running two proxy protocols for travel in
mainland China (WhatsApp, YouTube, OpenRouter, Anthropic, Meta) from
iOS, macOS and Android.

- **Xray VLESS-REALITY** on TCP 443 (certless, SNI-masqueraded as
  `www.amazon.com`; works via IP before DNS propagates)
- **Hysteria2** on UDP 443 with a real ACME cert for your own domain
  (http-01 on port 80; TCP 443 belongs to Xray so tls-alpn-01 is impossible)

OpenTofu owns the infra. `user_data` (first boot only) installs Docker and
starts both services from prebuilt upstream images — nothing is built on the
VPS. All config changes after creation go through `scripts/redeploy.sh`.

## Layout

| Path | Purpose |
| ---- | ------- |
| `tofu/` | Instance + static IP + firewall + first-boot bootstrap |
| `docker/compose.yml` | Xray + Hysteria2 services (images pinned via variables) |
| `docker/xray/config.json.tmpl` | VLESS inbound `xtls-rprx-vision` + REALITY |
| `docker/hysteria/config.yaml.tmpl` | Hy2 `listen :443`, ACME http-01, password auth |
| `scripts/generate-secrets.sh` | Secret + client-config generation (Mac only) |
| `scripts/redeploy.sh` | Only supported config-update path (SSH) |
| `scripts/mirror-to-ecr.sh` | Fallback: verbatim upstream-image mirror to ECR |

Generated and never committed: `secrets/`, `clients/`, `tofu/tofu.tfvars`,
`tofu/terraform.tfstate*` (see `.gitignore`). Note: Tofu state embeds
secrets via `user_data` — keep it local, `chmod 600`, never commit.

## Prerequisites

- `opentofu >= 1.8`, `aws` CLI with credentials (`AWS_REGION=ap-southeast-1`),
  `docker` on the Mac (only used for REALITY key generation), `dig`
- Your own domain with DNS access (for Hy2 ACME)
- `sing-box` binary if you want to `check` the generated client config

Pinned images (exact tags, see `tofu/variables.tf`):
`ghcr.io/xtls/xray-core:26.3.27`, `tobyxdd/hysteria:v2.12.3`.

## Bring-up (in order)

1. `./scripts/generate-secrets.sh` — prompts for `domain_name` + `acme_email`,
   writes `secrets/`, `tofu/tofu.tfvars`, `clients/sing-box.json`, prints both
   share links (`vless://…`, `hy2://…`). Links use the domain; before DNS
   propagates, swap the host for the static IP (Xray works via IP immediately).
2. `cd tofu && tofu init && tofu plan -var-file=tofu.tfvars -out=tfplan` —
   expect 4 resources: instance, static IP, attachment, public ports.
3. `tofu apply tfplan`, note the `static_ip` output. Save the SSH key once:
   `tofu output -raw ssh_private_key_pem > ~/.ssh/china-proxy.pem && chmod 600 ~/.ssh/china-proxy.pem`.
4. DNS `A <domain> -> <static_ip>`; wait for `dig +short <domain>` to match
   before testing Hy2 (`docker logs hysteria` shows issuance; it retries).
5. Import `clients/sing-box.json` or the share links into Hiddify/Streisand
   (iOS/macOS) or v2rayNG/NekoBox (Android). `china-auto` urltests both
   outbounds; private IPs + `geosite: cn` go direct.

## Updating config

Never edit files on the VPS, never expect `tofu apply` to re-run `user_data`
(Lightsail runs it on first boot only):

```sh
./scripts/redeploy.sh            # renders locally, scp to /opt/proxy, compose pull/up
```

`SSH_KEY` env overrides the key path (default `~/.ssh/china-proxy.pem`).

## Fallbacks

- **Pulls from Docker Hub/ghcr.io fail on the VPS:** `./scripts/mirror-to-ecr.sh`,
  then point `xray_image`/`hy2_image` at the printed ECR URIs. Nothing else changes.
- **REALITY handshake/SNI issues:** `reality_dest="www.apple.com:443"` +
  `reality_server_name="www.apple.com"`, regenerate nothing, `redeploy.sh`.
  Never use `www.microsoft.com` as dest (handshake exceeds Xray's 8192-byte
  limit, XTLS/Xray-core#6356).
- **UDP 443 throttled:** move Hy2 to `listen ":8443"` + a UDP 8443 firewall
  block + client port `8443`; keep Xray on TCP 443.
- **Singapore slow/blocked:** `az=ap-northeast-1a`, `aws_region=ap-northeast-1`,
  re-apply (new static IP, update DNS A).

## Firewall (Lightsail, authoritative)

22/tcp (SSH, `ssh_allowed_cidr` — tighten once your IP is known),
80/tcp (ACME http-01 only), 443/tcp (Xray), 443/udp (Hy2). Host `ufw` is
disabled by `user_data` so it can't shadow these.
