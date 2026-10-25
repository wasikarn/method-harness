#!/usr/bin/env bash
# doctrine-bootstrap.sh's python3-missing message must name every gate in
# hooks/gates/*.sh, derived at run time -- not a hand-maintained list (LOW,
# harness gap-audit 2026-09-20: the old hardcoded string named 5 of the 7
# real gate wrappers, silently missing subagent-spawn-guard and
# codex-setup-guard). This test proves the list tracks the fleet: it builds a
# fixture gates/ dir, runs the script with python3 hidden from PATH, and
# checks a newly-added fixture gate shows up in the message without any
# script edit.
# Run standalone: bash tests/hooks/test-doctrine-bootstrap.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/hooks/session/doctrine-bootstrap.sh"

pass=0
fail=0
assert() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

fixture=$(mktemp -d)
mkdir -p "$fixture/docs" "$fixture/hooks/gates"
echo "# fixture methodology" > "$fixture/docs/METHODOLOGY.md"
: > "$fixture/hooks/gates/alpha-gate.sh"
: > "$fixture/hooks/gates/beta-gate.sh"

# PATH with only what the script itself needs (cat, basename) and none of
# python3/jq/node, so the three preflight checks all fire without touching
# the real system tools.
noop_bin=$(mktemp -d)
ln -s /bin/cat "$noop_bin/cat"
ln -s /usr/bin/basename "$noop_bin/basename"
strip_path="$noop_bin"

out=$(CLAUDE_PLUGIN_ROOT="$fixture" PATH="$strip_path" /bin/bash "$SCRIPT" 2>/dev/null)

/usr/bin/grep -q "alpha-gate" <<<"$out" && /usr/bin/grep -q "beta-gate" <<<"$out" && ok=1 || ok=0
assert "python3-missing message names every current hooks/gates/*.sh file" "$ok"

# Add a third gate to the fixture -- the message must pick it up without any
# script change, proving the list isn't hardcoded.
: > "$fixture/hooks/gates/gamma-gate.sh"
out2=$(CLAUDE_PLUGIN_ROOT="$fixture" PATH="$strip_path" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "gamma-gate" <<<"$out2" && ok=1 || ok=0
assert "a newly-added gate file appears in the message with no script edit" "$ok"

# (2026-09-21) The glob-empty fallback used to be a second hand-maintained
# literal list (7 names, hooks/gates/ had 8). No real gate basename may appear
# in the script's code lines at all; comments are stripped first because the
# history note above the loop legitimately names two gates.
hardcoded=0
for g in "$ROOT"/hooks/gates/*.sh; do
  name=$(basename "$g" .sh)
  sed 's/#.*$//' "$SCRIPT" | /usr/bin/grep -q -- "$name" && hardcoded=$((hardcoded + 1))
done
[[ "$hardcoded" == "0" ]] && ok=1 || ok=0
assert "no real gate name is hardcoded in the script's code (found $hardcoded)" "$ok"

trash "$fixture" "$noop_bin" 2>/dev/null || true

echo
echo "doctrine-bootstrap: $pass passed, $fail failed"
[[ "$fail" == "0" ]]
