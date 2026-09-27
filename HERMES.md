# HERMES.md — agent runbook for china-proxy

You (Hermes) run on the home network with normal internet. The user invokes
you over QQ, including while the proxy is down. Every flow below is
non-interactive: all inputs come from env/files, never prompts.

## Status (2026-09-27)

Built: `generate-secrets.sh`, `redeploy.sh`, `setup-dns.sh` (incl.
`--skip-acme-check`), `mirror-to-ecr.sh`, `certs-backup/restore.sh`,
`sleep.sh`/`wake.sh`, tofu stack. Standing decisions: `small_3_0` stays, both
protocols always on (no single-service mode), no IPv6, Hermes-local cert
store (no S3), ECR holds verbatim upstream images only (no builds).

## 0. Host prerequisites (one time)

Repo checked out at `$REPO`; `tofu` + `aws` CLI + `sing-box` installed;
`SSH_KEY=~/.ssh/china-proxy.pem` (chmod 600, from
`tofu -chdir=$REPO/tofu output -raw ssh_private_key_pem`);
`CLOUDFLARE_API_TOKEN` exported (Cloudflare → My Profile → API Tokens →
"Edit zone DNS", scoped to the zone); AWS creds with Lightsail rights;
`AWS_REGION=ap-southeast-1` default. Local state dir
`$CERT_STORE=$HOME/.china-proxy/certs/<domain>/` (create it; never commit,
never transmit except over SSH to the VPS).

Fixed facts: VPS user `ubuntu`; server files under `/opt/proxy`
(`docker-compose.yml`, `xray/config.json`, `hysteria/config.yaml`);
compose services `xray` (TCP 443) and `hysteria` (UDP 443 + TCP 80);
DNS record is always DNS-only (grey cloud) — never orange-cloud.
`REPO/tofu/tofu.tfvars` holds domain/email/secrets; `REPO/clients/`
holds share links. **Never regenerate secrets on a live deployment**
(clients would orphan); only `generate-secrets.sh` on first setup or
explicit rotation.

After EVERY flow: verify (§8) and report over QQ (§9).

1. `ssh -i $SSH_KEY -o ConnectTimeout=10 ubuntu@$(tofu -chdir=$REPO/tofu output -raw static_ip) true`

1. `DOMAIN_NAME=<sub.domain> ACME_EMAIL=<mail> $REPO/scripts/generate-secrets.sh`
   (skip if `tofu.tfvars` already matches the intended domain).
2. `sing-box check -c $REPO/clients/sing-box.json` — must exit 0.
3. `tofu -chdir=$REPO/tofu init && tofu plan -var-file=tofu.tfvars -out=tfplan`
   — expect 4 resources (instance, static IP, attachment, public ports).
4. `tofu apply tfplan`; record `static_ip`. Save SSH key if missing (see §0).
5. `CLOUDFLARE_API_TOKEN=... $REPO/scripts/setup-dns.sh` — creates the A
   record, waits for propagation, confirms ACME issuance. Exit 0 = cert live.
6. Verify (§8) both protocols; report (§9).

## B. Diagnose "lost connectivity" (always first)

Both protocols always run, so there is nothing to switch server-side;
protocol choice is client-side. Test each from your own egress (§8):
1. `ssh -i $SSH_KEY -o ConnectTimeout=10 ubuntu@$(tofu -chdir=$REPO/tofu output -raw static_ip) true`
   - Alive → check `docker ps`: dead container → §C (repair). Both Up but one
     protocol fails egress → no server action: tell the user to use the
     working outbound client-side.
   - Dead → is it the IP or the box? `aws lightsail get-instance
     --instance-name china-proxy` (state?) and a TCP probe on 443. No SSH +
     instance RUNNING = IP-level block → §D (same region, new IP). If a fresh
     same-region IP also fails quickly, or the region is widely flagged → §E.

## C. Same-box repair (fast, no DNS, no ACME)

Both services always run; nothing starts or stops selectively. Repair = push
fresh configs and recreate both containers:
1. `$REPO/scripts/redeploy.sh` (renders locally, `scp` to `/opt/proxy`,
   `compose pull && up -d`, prints `docker ps`).
2. `docker ps` shows xray AND hysteria Up. Same IP, same valid cert — no DNS
   change, no issuance.
3. Verify (§8) both protocols; report (§9).

## D. Same-region rebuild (new IP, SSH dead)

1. Certs cannot be exported (box unreachable) — accept one fresh LE issuance
   (ladder discipline: §B→§C come first; LE allows ~5 duplicate certs/week).
2. `tofu -chdir=$REPO/tofu destroy -var-file=tofu.tfvars -auto-approve`
   (instance AND static IP — never `stop`; orphan IPs bill $0.005/hr).
3. `$REPO/scripts/wake.sh` — applies, waits for first boot (~3–6 min), then
   fresh-issues (no bundle exists for an unreachable box) via `setup-dns.sh`.
4. Verify (§8); report (§9) with the new IP.

## E. New-region rebuild (region flagged)

Identical to §D, but destroy first, then wake with overrides, e.g.
`$REPO/scripts/wake.sh -var='aws_region=ap-northeast-1' -var='az=ap-northeast-1a'`
(Tokyo). Note: opt-in regions must be enabled in the account first or the
API call fails — surface that error to the user. If the region ever gets
pinned, write it into `tofu.tfvars`-adjacent Hermes config, not into
`variables.tf` defaults.

## F. Sleep (user going to bed — delete everything billable)

1. `$REPO/scripts/sleep.sh` — backs up the cert bundle (warns and continues
   when there is nothing to back up), destroys instance AND static IP with
   `-auto-approve`, then fails if either still exists.
2. Leave the DNS record in place (stale target fails closed; avoids
   negative-cache quirks on wake). Report (§9): destroyed, cert backed up
   (expiry date), billing stopped.

## G. Wake (rebuild, ~5–10 min — set expectations in the reply)

1. `$REPO/scripts/wake.sh` (extra tofu args pass through, e.g. region vars)
   — applies, polls first boot, restores the bundle when present (no LE
   issuance; certmagic resumes from cache) else fresh-issues, updates DNS,
   waits for propagation.
2. Verify (§8) with emphasis on Hy2 (bundle expiry printed by the scripts,
   both containers Up, egress test through `china-hy2`).
3. Report (§9): new IP, cert expiry, test results.

## H. VPS cannot pull images (user_data docker pull fails)

Symptom: first boot never yields Up containers; cloud-init/docker errors
mention registry timeouts. Run `$REPO/scripts/mirror-to-ecr.sh`, set
`xray_image`/`hy2_image` to the printed ECR URIs (tfvars overrides, not
defaults), re-apply/redeploy. ECR holds verbatim upstream images — no builds.

## 8. Verification standard (end of every flow)

- `docker ps --format '{{.Names}} {{.Status}}'` — expected services Up.
- `dig +short <domain> @1.1.1.1` == `tofu output -raw static_ip` (Hy2 flows).
- Egress per active protocol from THIS host (normal internet — a true
  end-to-end test): `sing-box run -c $REPO/clients/sing-box.json` exposing a
  local mixed inbound, then per-outbound `curl -x socks5h://127.0.0.1:1080
  -s https://www.youtube.com --max-time 15 | head -c 200` (HTML) and
  `https://openrouter.ai/api/v1/models` (any JSON). Force each active
  outbound in turn.
- Any check failing twice → escalate (§10), do not loop forever.

## 9. QQ report format (every flow)

One message: flow (A–H) + region + `static_ip` + active protocol(s) +
verify results (YouTube/OpenRouter per protocol, `dig` match y/n) +
cert expiry (Hy2 flows) + cost note if resources were destroyed/created.
Wake replies lead with ETA; sleep replies confirm billing stopped.

## 10. Escalate to the user (stop, report, wait)

LE rate-limit/duplicate errors; DNS not propagating >30 min; AWS
quota/API/region-opt-in errors; both protocols failing after a rebuild;
any step failing twice; anything asking for a secret you don't have.
