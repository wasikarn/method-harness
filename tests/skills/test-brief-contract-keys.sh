#!/usr/bin/env bash
# A checker brief shows the JSON shape its agent must return. Codex is held to the schema by
# --output-schema, but the Claude fallback only has the brief: a key the brief's example leaves
# out is a key the agent leaves out, and check-verdict.py then rejects a reply that followed the
# brief to the letter (idea-audit and compliance-audit both omitted contract_version).
# Doc check: every top-level key the schema requires is named, quoted, in the brief.
# Run standalone: bash tests/skills/test-brief-contract-keys.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
ok() { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

check_pair() { # <brief> <schema>, both relative to the repo root
  local brief="$ROOT/$1" schema="$ROOT/$2" missing
  if [ ! -f "$brief" ] || [ ! -f "$schema" ]; then
    bad "$1 or $2 is missing"
    return
  fi
  missing="$(python3 - "$brief" "$schema" <<'PY'
import json, sys
brief = open(sys.argv[1], encoding="utf-8").read()
required = json.load(open(sys.argv[2], encoding="utf-8"))["required"]
print(" ".join(k for k in required if '"%s"' % k not in brief))
PY
  )" || { bad "$2 could not be read as a schema with a required list"; return; }
  if [ -z "$missing" ]; then
    ok "$1 names every required key of $2"
  else
    bad "$1 does not name required key(s): $missing"
  fi
}

check_pair skills/workflow/idea-audit/references/attacker-brief.md \
  skills/workflow/idea-audit/references/attacker-output-schema.json
check_pair skills/review/compliance-audit/references/verifier-brief.md \
  skills/review/compliance-audit/references/verifier-output-schema.json

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
