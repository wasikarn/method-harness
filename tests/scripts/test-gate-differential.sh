#!/usr/bin/env bash
# scripts/gate-differential.sh (GH #411): old-vs-new gate replay that prints diff classes only.
# Checks: identical copies give 0 diffs; a planted one-rule change gives exactly its class and
# never prints the secret-shaped command it replayed; a --slug outside this project is refused;
# --replay reads only this project's transcript dirs; the real gate journal is never written.
# Run standalone: bash tests/scripts/test-gate-differential.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../_lib/harness.sh
. "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
SCRIPT="$ROOT/scripts/gate-differential.sh"
GATES="$ROOT/hooks/gates"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

T=$(fresh_tmpdir)
[ -n "$T" ] && [ -d "$T" ] || { echo "FAIL: no tmpdir" >&2; exit 1; }
# A fake HOME holding a seeded "real" journal: every run below must leave it at 3 lines.
export HOME="$T/home"
JOURNAL="$HOME/.local/share/kbg/metrics/gate-decisions.jsonl"
mkdir -p "$(dirname "$JOURNAL")"
printf '{"seed":1}\n{"seed":2}\n{"seed":3}\n' > "$JOURNAL"
unset MH_GATE_JOURNAL_PATH
export CLAUDE_CONFIG_DIR="$T/cc"

cp -R "$GATES" "$T/old"
cp -R "$GATES" "$T/same"
cp -R "$GATES" "$T/planted"
# The planted one-rule change: drop the npm pattern from secret-scan.py.
awk '!/\("npm", re\.compile/' "$GATES/secret-scan.py" > "$T/planted/secret-scan.py"
if cmp -s "$GATES/secret-scan.py" "$T/planted/secret-scan.py"; then
  bad "planting the npm rule edit changed nothing (pattern line moved?)"
fi

# Built, never written whole: a live-shaped npm token (no repeated or ascending run).
tok="npm_""$(printf 'Zq8Lm3%.0s' 1 2 3 4 5 6)"
printf 'plain text, no token\nkey=%s\n' "$tok" > "$T/cases.txt"

echo "=== identical copies ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" "$T/old" "$T/same" secret-scan 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "identical copies: exit 0, diffs=0"
else bad "identical copies (rc=$rc): $out"; fi

echo "=== planted one-rule change ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" "$T/old" "$T/planted" secret-scan 2>&1); rc=$?
classes=$(printf '%s\n' "$out" | /usr/bin/grep -c '^  \[')
if [ "$rc" -eq 1 ] && [ "$classes" -eq 1 ] \
   && /usr/bin/grep -q '^  \[1\] stdout | journal ask->none$' <<<"$out"; then
  ok "planted change: exactly one class, 'stdout | journal ask->none', count 1"
else bad "planted change (rc=$rc, classes=$classes): $out"; fi
case "$out" in
  *Zq8Lm3*) bad "planted change: output leaked the secret-shaped command" ;;
  *'[REDACTED]'*) ok "planted change: command redacted" ;;
  *) bad "planted change: no redacted sample shown: $out" ;;
esac

echo "=== git ref as OLD ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" HEAD "$T/same" secret-scan 2>&1); rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then ok "git ref OLD resolves (rc=$rc)"
else bad "git ref OLD (rc=$rc): $out"; fi

echo "=== slug outside the project ==="
out=$(bash "$SCRIPT" --replay 3 --slug -home-someone-else "$T/old" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'refusing' <<<"$out"; then
  ok "foreign --slug refused with exit 2"
else bad "foreign --slug (rc=$rc): $out"; fi

echo "=== replay reads this project only ==="
main=$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)
slug=$(cd -P "$main/.." && pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug/s1/subagents" "$CLAUDE_CONFIG_DIR/projects/${slug}x"
use() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$1"; }
use 'rm -rf build' > "$CLAUDE_CONFIG_DIR/projects/$slug/a.jsonl"
use 'ls -la' > "$CLAUDE_CONFIG_DIR/projects/$slug/s1/subagents/agent-1.jsonl"
{ use 'echo other1'; use 'echo other2'; } > "$CLAUDE_CONFIG_DIR/projects/${slug}x/b.jsonl"
: > "$T/empty.txt"
out=$(bash "$SCRIPT" --cases "$T/empty.txt" --replay 50 "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'replay=2 ' <<<"$out"; then
  ok "replay sampled the 2 commands of this project, none from a sibling-named project"
else bad "replay (rc=$rc): $out"; fi

echo "=== slug traversal out of a worktree prefix ==="
out=$(bash "$SCRIPT" --replay 3 --slug "$slug--claude-worktrees-probe/../foreign" "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'refusing' <<<"$out"; then
  ok "--slug with ../ refused with exit 2"
else bad "--slug traversal (rc=$rc): $out"; fi

echo "=== fuzz ==="
# A small --cases corpus: fuzz still draws its 200 mutations, but the run no longer replays the
# whole irrecoverable fixture set twice (~560 gate spawns, ~60 s). Gate verdicts on that set are
# tests/hooks' job; this file covers the harness, and fixture parsing is checked directly below.
printf 'rm -rf build\ngit reset --hard\n' > "$T/deny.txt"
out=$(bash "$SCRIPT" --cases "$T/deny.txt" --fuzz-seed 7 "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -Eq 'fuzz=[1-9][0-9]*\)' <<<"$out"; then
  ok "fuzz adds seeded cases, 0 diffs on identical copies"
else bad "fuzz (rc=$rc): $out"; fi

echo "=== fixture parsing ==="
# The default corpus (no --cases) is the committed fixtures; parse them without running the gate.
n=$(python3 - "$ROOT/scripts/_lib/gate-differential.py" "$ROOT/tests/hooks/fixtures" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
print(len(gd.fixture_cases(sys.argv[2], "irrecoverable")))
PY
)
if [ "$n" -ge 50 ] 2>/dev/null; then ok "fixture corpus parses ($n irrecoverable cases)"
else bad "fixture corpus did not parse (want >=50 cases): $n"; fi

echo "=== real journal untouched ==="
out=$(bash "$SCRIPT" --cases "$T/deny.txt" "$T/old" "$T/same" irrecoverable 2>&1)
n=$(wc -l < "$JOURNAL" | tr -d ' ')
if [ "$n" -eq 3 ]; then ok "real journal still 3 lines after the deny runs"
else bad "real journal grew to $n lines: $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "PASS: test-gate-differential"
exit "$fail"
