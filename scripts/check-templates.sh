#!/bin/bash
# Regression guard: every ${var} used in user_data + docker templates must be
# supplied by main.tf's templatefile calls. tofu validate does NOT check this
# (templatefile vars resolve only at plan/apply) — a miss breaks destroy/apply
# at runtime, as happened with COMPOSE_VERSION. Run before committing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PYEOF'
import re, sys
main = open('tofu/main.tf').read()
# vars passed in each templatefile({...}) call
passed = set(re.findall(r'(\w+)\s*=\s*(?:var\.|local\.)', main))
ok = True
for tmpl in ['tofu/user_data.tmpl.sh', 'docker/compose.yml',
             'docker/xray/config.json.tmpl', 'docker/hysteria/config.yaml.tmpl']:
    used = set(re.findall(r'\$\{(\w+)\}', open(tmpl).read()))
    missing = used - passed
    # shell variables assigned in user_data itself don't need passing
    if tmpl == 'tofu/user_data.tmpl.sh':
        assigned = set(re.findall(r'^([A-Z_]+)=', open(tmpl).read(), re.M))
        missing -= assigned
    if missing:
        print('%s: unprovided template vars: %s' % (tmpl, sorted(missing)))
        ok = False
    else:
        print('%-32s OK %s' % (tmpl, sorted(used)))
sys.exit(0 if ok else 1)
PYEOF
