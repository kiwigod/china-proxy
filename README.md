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
| `scripts/generate-secrets.sh` | Secret + client-config generation (Mac or Hermes host — needs docker) |
PUT 29.<30:
| `scripts/check-templates.sh` | Template-var + compose-structure guard — run before committing |
| `scripts/redeploy.sh` | Only supported config-update path (SSH) |
| `scripts/setup-dns.sh` | Cloudflare A record + propagation wait + ACME confirm |
| `scripts/certs-backup/restore.sh` | Hermes-local TLS bundle export/import (no LE reissue) |
| `scripts/sleep.sh` / `wake.sh` | Hermes teardown/rebuild (destroy vs. apply+inject+DNS) |
| `scripts/mirror-to-ecr.sh` | Fallback: verbatim upstream-image mirror to ECR |
| `scripts/check-templates.sh` | Template-var + compose-structure guard — run before committing |
| `HERMES.md` | Agent runbook: diagnose, switch region, sleep/wake, report |

Generated and never committed: `secrets/`, `clients/`, `tofu/tofu.tfvars`,
`tofu/terraform.tfstate*`, `tofu/tfplan`, `tofu/.terraform/`, `.env`
(see `.gitignore`). Note: Tofu state embeds
secrets via `user_data` — keep it local, `chmod 600`, never commit.

## Prerequisites

- `opentofu >= 1.8`, `aws` CLI with credentials (export `AWS_REGION=ap-southeast-1`
  to match `var.aws_region` — the tofu provider region comes from the variable,
  not the env), `docker` (REALITY keygen + ECR mirroring), `dig`,
  `python3`, `openssl`, `uuidgen`, `curl`, `ssh`/`scp`, `tar`, `ssh-keygen`
- Your own domain with DNS access (for Hy2 ACME)
- `sing-box` binary if you want to `check` the generated client config

Pinned images (exact tags, see `tofu/variables.tf`):
`ghcr.io/xtls/xray-core:26.3.27`, `tobyxdd/hysteria:v2.12.3`.

## Bring-up (in order)

Run steps 1 and 4–6 from the repo root (step 4's `tofu -chdir=` works anywhere); steps 2–3 inside `tofu/`.

1. `./scripts/generate-secrets.sh` — prompts for `domain_name` + `acme_email`,
   writes `secrets/`, `tofu/tofu.tfvars`, `clients/sing-box.json`, prints both
   share links (`vless://…`, `hy2://…`). Links use the domain; before DNS
   propagates, swap the host for the static IP (Xray works via IP immediately).
   One-time per deployment — never re-run on a live setup (it rotates all
   secrets and orphans existing clients); config changes go through `redeploy.sh`.
2. `cd tofu && tofu init && tofu plan -var-file=tofu.tfvars -out=tfplan` —
   expect 5 resources: key pair, instance, static IP, attachment, public ports.
3. `tofu apply tfplan`, note the `static_ip` output. Save the SSH key:
   `mkdir -p ~/.ssh && tofu output -raw ssh_private_key_pem > ~/.ssh/china-proxy.pem && chmod 600 ~/.ssh/china-proxy.pem`.
4. Wait ~3–6 min for first boot (`user_data` starts xray only, so an empty
   volume never fires a doomed ACME order), then start Hysteria for issuance:
   `ssh -i ~/.ssh/china-proxy.pem ubuntu@$(tofu -chdir=tofu output -raw static_ip) 'docker compose -f /opt/proxy/docker-compose.yml up -d hysteria'` (repeat until it succeeds — SSH appears before Docker is ready).
5. From the repo root: `./scripts/setup-dns.sh` (needs `CLOUDFLARE_API_TOKEN` env — Cloudflare
   dashboard → My Profile → API Tokens → "Edit zone DNS" template, scoped to
   your zone). Creates/updates the `A <domain> -> <static_ip>` record as
   DNS-only, waits for propagation, then confirms Hysteria's ACME issuance
   over SSH. Manual equivalent: grey-clouded A record in DNS → Records, wait
   for `dig +short <domain>` to match, check
   `docker compose -f /opt/proxy/docker-compose.yml logs hysteria` on the VPS.
6. Import `clients/sing-box.json` or the share links into Hiddify/Streisand
   (iOS/macOS) or v2rayNG/NekoBox (Android). `china-auto` urltests both
   outbounds; private IPs + `geosite: cn` go direct.

## Updating config

Never edit files on the VPS, never expect `tofu apply` to re-run `user_data`
(Lightsail runs it on first boot only):

```sh
./scripts/redeploy.sh            # renders locally, scp to /opt/proxy, compose pull/up
```

`SSH_KEY` env overrides the key path (default `~/.ssh/china-proxy.pem`).
After touching `tofu/` or `docker/` templates: `./scripts/check-templates.sh`.

## Fallbacks

- **Pulls from Docker Hub/ghcr.io fail on the VPS:** `./scripts/mirror-to-ecr.sh`,
  then point `xray_image`/`hy2_image` at the printed ECR URIs. Nothing else changes.
- **REALITY handshake/SNI issues:** set `reality_dest="www.apple.com:443"` +
  `reality_server_name="www.apple.com"` in `tofu/variables.tf` (or tfvars
  overrides — `redeploy.sh` honors tfvars first), regenerate nothing,
  `redeploy.sh`, then update the SNI in `clients/sing-box.json` +
  `clients/xray-link.txt` (sed amazon→apple) and re-import on every device:
  the server change alone breaks the handshake for old-SNI clients.
  Never use `www.microsoft.com` as dest (handshake exceeds Xray's 8192-byte
  limit, XTLS/Xray-core#6356).
- **UDP 443 throttled** (advanced, manual — no script support): `listen ":8443"`
  in `docker/hysteria/config.yaml.tmpl` + `"8443:8443/udp"` in
  `docker/compose.yml` + a UDP 8443 `port_info` block in `tofu/main.tf`, then
  `redeploy.sh`, change client port to `8443` in `clients/sing-box.json` +
  `clients/hy2-link.txt`, re-import; keep Xray on TCP 443.
- **Singapore slow/blocked:** `tofu apply -var='az=ap-northeast-1a'
  -var='aws_region=ap-northeast-1'` (or append both to `tofu.tfvars`), then
  re-run `setup-dns.sh` for the new IP (fresh ACME issuance on the new box;
  back up certs first if near LE limits).

## Firewall (Lightsail, authoritative)

22/tcp (SSH, `ssh_allowed_cidr` — tighten once your IP is known),
80/tcp (ACME http-01 only), 443/tcp (Xray), 443/udp (Hy2). Host `ufw` is
disabled by `user_data` so it can't shadow these.
