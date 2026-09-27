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

First: `export REPO=$HOME/china-proxy` (adjust to your checkout),
`export SSH_KEY=$HOME/.ssh/china-proxy.pem CLOUDFLARE_API_TOKEN=... AWS_REGION=ap-southeast-1`
(or `set -a; . $REPO/.env; set +a`). Then: repo checked out at `$REPO`;
`tofu` + `aws` CLI + `sing-box` + `docker` + `python3` + `openssl` + `uuidgen`
+ `curl` + `ssh`/`scp` + `tar` + `ssh-keygen` + `dig` installed;
`$SSH_KEY` (chmod 600, via
`tofu -chdir=$REPO/tofu output -raw ssh_private_key_pem > $SSH_KEY && chmod 600 $SSH_KEY`);
`CLOUDFLARE_API_TOKEN` exported (Cloudflare → My Profile → API Tokens →
"Edit zone DNS", scoped to the zone); AWS creds with Lightsail rights.
Local state dir `$CERT_STORE=$HOME/.china-proxy/certs/<domain>/` (create it;
never commit, never transmit except over SSH to the VPS).

Fixed facts: VPS user `ubuntu`; server files under `/opt/proxy`
(`docker-compose.yml`, `xray/config.json`, `hysteria/config.yaml`);
compose services `xray` (TCP 443) and `hysteria` (UDP 443 + TCP 80);
DNS record is always DNS-only (grey cloud) — never orange-cloud.
`$REPO/tofu/tofu.tfvars` holds domain/email/secrets; `$REPO/clients/`
holds share links. **Never regenerate secrets on a live deployment**
(clients would orphan); only `generate-secrets.sh` on first setup or
explicit rotation.

After EVERY flow: verify (§8) and report over QQ (§9).

## A. Fresh build (first setup)

1. `DOMAIN_NAME=<sub.domain> ACME_EMAIL=<mail> $REPO/scripts/generate-secrets.sh`
   (skip if `tofu.tfvars` already matches the intended domain).
2. `sing-box check -c $REPO/clients/sing-box.json` — must exit 0.
3. `tofu -chdir=$REPO/tofu init && tofu -chdir=$REPO/tofu plan -var-file=tofu.tfvars -out=tfplan`
   — expect 5 resources (key pair, instance, static IP, attachment, public ports).
4. `tofu -chdir=$REPO/tofu apply tfplan`; record `static_ip`. Save SSH key if
   missing or stale (after any destroy the key pair is recreated — always
   re-save here): `tofu -chdir=$REPO/tofu output -raw ssh_private_key_pem > $SSH_KEY && chmod 600 $SSH_KEY`.
5. `CLOUDFLARE_API_TOKEN=... $REPO/scripts/setup-dns.sh` — creates the A
   record, waits for propagation, confirms ACME issuance. Exit 0 = cert live.
6. Verify (§8) both protocols; report (§9).

## B. Diagnose "lost connectivity" (always first)

Both protocols always run, so there is nothing to switch server-side;
protocol choice is client-side. Test each from your own egress (§8):
1. `ssh -i $SSH_KEY -o ConnectTimeout=10 ubuntu@$(tofu -chdir=$REPO/tofu output -raw static_ip) true`
   - Alive → check containers over the same SSH:
     `ssh -i $SSH_KEY ubuntu@$(tofu -chdir=$REPO/tofu output -raw static_ip) 'docker compose -f /opt/proxy/docker-compose.yml ps'`.
     Dead container → §C (repair). Both Up but one protocol fails egress →
     no server action: tell the user to use the working outbound client-side.
   - Dead → is it the IP or the box?
     `aws lightsail get-instance --instance-name "${INSTANCE_NAME:-china-proxy}" --region "${AWS_REGION:-ap-southeast-1}"`
     plus a TCP probe: `IP=$(tofu -chdir=$REPO/tofu output -raw static_ip); timeout 10 bash -c "</dev/tcp/$IP/443" && echo open || echo closed`.
     No SSH + instance RUNNING = IP-level block → §D (same region, new IP).
     If a fresh same-region IP also fails quickly, or the region is widely flagged → §E.

## C. Same-box repair (fast, no DNS, no ACME)

Both services always run; nothing starts or stops selectively. Repair = push
fresh configs and recreate both containers:
1. `$REPO/scripts/redeploy.sh` (renders locally, `scp` to `/opt/proxy`,
   `compose pull && up -d`; its trailing `docker ps` runs on the VPS over SSH
   and shows proxy-xray-1 AND proxy-hysteria-1 Up).
2. Same IP, same valid cert — no DNS change, no issuance.
3. Verify (§8) both protocols; report (§9).

## D. Same-region rebuild (new IP, SSH dead)

1. Certs cannot be exported (box unreachable) — accept one fresh LE issuance
   (ladder discipline: §B→§C come first; LE allows ~5 duplicate certs/week).
2. `tofu -chdir=$REPO/tofu destroy -var-file=tofu.tfvars -auto-approve`
   (instance AND static IP — never `stop`; orphan IPs bill $0.005/hr).
3. `$REPO/scripts/wake.sh` — applies, waits for first boot (~3–6 min), re-saves
   the recreated SSH key over `$SSH_KEY`, then restores the existing local
   bundle when present (no LE issuance) else fresh-issues via `setup-dns.sh`.
4. Verify (§8); report (§9) with the new IP.

## E. New-region rebuild (region flagged)

Identical to §D, but destroy first, then wake with overrides, e.g.
`$REPO/scripts/wake.sh -var='aws_region=ap-northeast-1' -var='az=ap-northeast-1a'`
(Tokyo). Note: opt-in regions must be enabled in the account first or the
API call fails — surface that error to the user. Persist a moved region by
appending `aws_region = "..."` and `az = "..."` to `$REPO/tofu/tofu.tfvars`
and exporting matching `AWS_REGION` (re-append after any `generate-secrets.sh`
run — it rewrites `tofu.tfvars` wholesale); never change `variables.tf` defaults.

## F. Sleep (user going to bed — delete everything billable)

1. `$REPO/scripts/sleep.sh` — backs up the cert bundle (warns and continues
   when there is nothing to back up), destroys instance AND static IP with
   `-auto-approve`, then fails if either still exists.
2. Leave the DNS record in place (stale target fails closed; avoids
   negative-cache quirks on wake). Report (§9): destroyed, cert backed up
   (expiry date), billing stopped.

## G. Wake (rebuild, ~5–10 min — set expectations in the reply)

1. `$REPO/scripts/wake.sh` (extra tofu args pass through, e.g. region vars)
   — applies (re-saving the recreated SSH key over `$SSH_KEY`), polls first boot,
   restores the bundle when present (no LE issuance; certmagic resumes from
   cache) else fresh-issues, updates DNS, waits for propagation.
2. Verify (§8) with emphasis on Hy2 (bundle expiry printed by the scripts,
   both containers Up, egress test through `china-hy2`).
3. Report (§9): new IP, cert expiry, test results.

## H. VPS cannot pull images (user_data docker pull fails)

Symptom: first boot never yields Up containers; cloud-init/docker errors
mention registry timeouts. Run `$REPO/scripts/mirror-to-ecr.sh`, set
`xray_image`/`hy2_image` to the printed ECR URIs (tfvars overrides, not
defaults), re-apply/redeploy. ECR holds verbatim upstream images — no builds.

## 8. Verification standard (end of every flow)

- `docker compose -f /opt/proxy/docker-compose.yml ps --format '{{.Service}} {{.State}}'` over SSH — expect `xray running` + `hysteria running` (container names carry the `proxy-` prefix, so always address services via compose, never bare `docker logs/restart <name>`).
- `DOMAIN=$(grep '^domain_name' $REPO/tofu/tofu.tfvars | cut -d'"' -f2); test "$(dig +short "$DOMAIN" @1.1.1.1)" = "$(tofu -chdir=$REPO/tofu output -raw static_ip)" && echo "dig match"` (Hy2 flows).
- Egress per protocol, both in turn (`china-xray`, then `china-hy2`), from THIS host:
  the generated config has no inbound and `final` auto-selects, so inject both
  per run — once per OUT in `china-xray china-hy2`:
  `python3 -c "import json; c=json.load(open('$REPO/clients/sing-box.json')); c['inbounds']=[{'type':'mixed','tag':'t','listen':'127.0.0.1','listen_port':1080}]; c['route']['final']='OUT'; json.dump(c,open('/tmp/sb-OUT.json','w'))"`
  then `sing-box run -c /tmp/sb-china-xray.json & curl -x socks5h://127.0.0.1:1080 -s https://www.youtube.com --max-time 15 | head -c 200; kill %1`
  (HTML expected; repeat for `china-hy2`, plus `https://openrouter.ai/api/v1/models` for any JSON).
- Cert expiry for the QQ report: bundle paths print it (`notAfter=`); after a
  fresh issuance fetch it with: `ssh -i $SSH_KEY ubuntu@$(tofu -chdir=$REPO/tofu output -raw static_ip) "V=\$(docker volume ls -q|grep hysteria-certs|head -n1|xargs docker volume inspect -f '{{.Mountpoint}}'); sudo openssl x509 -enddate -noout -in \$(sudo find \$V -name '*.crt'|head -n1)"`.
- Any check failing twice → escalate (§10), do not loop forever.

## 9. QQ report format (every flow)

One message: flow (A–H) + region + `static_ip` + both protocols +
verify results (YouTube/OpenRouter per protocol, `dig` match y/n) +
cert expiry (Hy2 flows) + cost note if resources were destroyed/created.
Wake replies lead with ETA; sleep replies confirm billing stopped.

## 10. Escalate to the user (stop, report, wait)

LE rate-limit/duplicate errors; DNS not propagating >30 min; AWS
quota/API/region-opt-in errors; both protocols failing after a rebuild;
any step failing twice; anything asking for a secret you don't have.
