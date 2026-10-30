#!/usr/bin/env bash
# test-gauntlet-plan.sh — GH #749: scripts/gauntlet-plan.sh maps changed paths to a gauntlet level and
# the tests to run, through the committed scripts/gauntlet-rules.txt. Fixture path lists go in on stdin
# (`-`), so these rows check the real rules file; one row runs the <base> form on a temp repo.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"
PLAN="$ROOT/scripts/gauntlet-plan.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet-plan.sh: changed paths -> level + tests (GH #749) ==="

# plan <path>...: the plan for those paths, read from the real rules at the repo root.
plan() { (cd "$ROOT" && printf '%s\n' "$@" | bash "$PLAN" -); }
level_of() { printf '%s\n' "$1" | sed -n 's/^level: //p'; }
tests_of() { printf '%s\n' "$1" | sed -n 's/^test: //p'; }
NL=$'\n'
has_test() { case "$NL$(tests_of "$1")$NL" in *"$NL$2$NL"*) return 0 ;; esac; return 1; }

# 1. docs and *.md only: low, nothing to test.
out=$(plan docs/reference/repo-gotchas.md docs/adr/0001-x.md CHANGELOG.md)
if [ "$(level_of "$out")" = low ] && [ -z "$(tests_of "$out")" ]; then ok "docs only gives low with no tests"
else bad "docs only: $out"; fi

# 2. a gate change: medium, with that gate's own suite and the cross-gate suites, and no other gate's.
out=$(plan hooks/gates/secret-scan.py)
if [ "$(level_of "$out")" = medium ] && has_test "$out" tests/hooks/test-secret-scan.sh && has_test "$out" tests/hooks/test-gate-canary.sh \
   && ! has_test "$out" tests/hooks/test-subagent-git-guard.sh; then
  ok "a gate change gives medium plus that gate's tests"
else bad "gate change: $out"; fi
if /usr/bin/grep -qx 'reason: hooks/gates/secret-scan.\* -> medium (hooks/gates/secret-scan.py)' <<<"$out"; then
  ok "the plan names the rule that fired"
else bad "no reason line for the gate rule: $out"; fi

# 3. shared code: tests/_lib/ is sourced by many tests, so full.
out=$(plan tests/_lib/harness.sh)
if [ "$(level_of "$out")" = full ] && [ -z "$(tests_of "$out")" ]; then ok "a tests/_lib/ change gives full"
else bad "tests/_lib: $out"; fi

# 4. a path no rule matches: full, and the reason names it.
out=$(plan nowhere/new-thing.xyz)
if [ "$(level_of "$out")" = full ] && /usr/bin/grep -qx 'reason: nowhere/new-thing.xyz is unmapped -> full' <<<"$out"; then
  ok "an unmapped path gives full"
else bad "unmapped: $out"; fi

# 5. mixed: the highest level wins (low + medium = medium; + an unmapped path = full).
out=$(plan docs/reference/repo-gotchas.md hooks/gates/secret-scan.py)
if [ "$(level_of "$out")" = medium ] && has_test "$out" tests/hooks/test-secret-scan.sh; then ok "docs + a gate gives medium"
else bad "docs + gate: $out"; fi
out=$(plan hooks/gates/secret-scan.py nowhere/new-thing.xyz docs/x.md)
if [ "$(level_of "$out")" = full ]; then ok "a gate + an unmapped path + docs gives full"
else bad "gate + unmapped: $out"; fi

# SELF: a changed test file runs itself; a deleted one is not selected.
out=$(plan tests/scripts/test-merge-pr.sh tests/scripts/test-gone-forever.sh)
if [ "$(tests_of "$out")" = tests/scripts/test-merge-pr.sh ]; then ok "a changed test file selects itself, a deleted one nothing"
else bad "SELF: $out"; fi

# The <base> form diffs <base>...HEAD in a git repo, with its own rules file at the top.
source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
R=$(fresh_repo)
[ -n "$R" ] || { bad "fresh_repo failed"; exit 1; }
mkdir -p "$R/scripts" "$R/src" "$R/tests"
printf 'src/* medium tests/t.sh\n*.md low\n' >"$R/scripts/gauntlet-rules.txt"
echo t >"$R/tests/t.sh"; echo a >"$R/src/a.txt"; echo d >"$R/doc.md"
git -C "$R" add scripts/gauntlet-rules.txt tests/t.sh src/a.txt doc.md
git -C "$R" commit -qm base
base=$(git -C "$R" rev-parse HEAD)
echo d2 >>"$R/doc.md"; git -C "$R" commit -qam docs
out=$(cd "$R" && bash "$PLAN" "$base")
if [ "$(level_of "$out")" = low ] && /usr/bin/grep -qx 'changed: doc.md' <<<"$out"; then ok "<base> form: a docs commit gives low"
else bad "<base> docs: $out"; fi
echo a2 >>"$R/src/a.txt"; git -C "$R" commit -qam src
out=$(cd "$R" && bash "$PLAN" "$base")
if [ "$(level_of "$out")" = medium ] && [ "$(tests_of "$out")" = tests/t.sh ]; then ok "<base> form: a src commit gives medium + its test"
else bad "<base> src: $out"; fi
if (cd "$R" && bash "$PLAN" no-such-ref >/dev/null 2>&1); then bad "a bad base did not fail"; else ok "a bad base exits non-zero"; fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
