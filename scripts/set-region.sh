#!/bin/bash
# Change deployment region without ever displaying secrets.
# Usage: ./scripts/set-region.sh <region> [az]
# Validates the region against the Lightsail API BEFORE touching .env, then
# upserts only the AWS_REGION/AWS_AZ lines (all other lines byte-identical).
# Creates .env from .env.example when missing. Confirm output shows only the
# two changed (non-secret) lines. Never cat or print .env wholesale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v aws >/dev/null 2>&1 || { echo "missing dependency: aws" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "missing dependency: python3" >&2; exit 1; }

REGION="${1:?usage: ./scripts/set-region.sh <region> [az]}"
AZ="${2:-${REGION}a}"
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] \
  || { echo "not an AWS region id: $REGION" >&2; exit 1; }

aws lightsail get-regions --query 'regions[].name' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -qx "$REGION" \
  || { echo "region unknown or not enabled on this account: $REGION" >&2; exit 1; }

ENV_FILE="$ROOT/.env"
[ -f "$ENV_FILE" ] || cp "$ROOT/.env.example" "$ENV_FILE"

REGION="$REGION" AZ="$AZ" python3 - <<'PYEOF'
import os, re
path = '.env'
src = open(path).read().splitlines(keepends=True)
def upsert(lines, key, val):
    pat = re.compile(r'^#?%s=.*(\n|$)' % key)
    hit = [i for i, l in enumerate(lines) if pat.match(l)]
    if hit:
        lines[hit[-1]] = '%s=%s\n' % (key, val)
    else:
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        lines.append('%s=%s\n' % (key, val))
    return lines
src = upsert(src, 'AWS_REGION', os.environ['REGION'])
src = upsert(src, 'AWS_AZ', os.environ['AZ'])
open(path, 'w').writelines(src)
PYEOF
chmod 600 "$ENV_FILE"
echo "region set:"
grep -E '^(AWS_REGION|AWS_AZ)=' "$ENV_FILE"
