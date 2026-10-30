#!/usr/bin/env bash
# test-gauntlet-levels.sh — GH #749: scripts/run-gauntlet.sh --level <l> --plan <base> runs the level
# scripts/gauntlet-plan.sh picks: medium runs only the planned test files and never records a pass, and a
# level below the plan's is refused before anything runs. The real run-gauntlet.sh runs in a fixture repo
# with its own rules and two recorder tests (running this repo's test layer here would recurse); only
# `claude`, check-observer-contract.sh and harness-audit's audit.sh are stubs.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== run-gauntlet.sh --level: medium runs the plan's tests, never records a pass (GH #749) ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
R=$(fresh_repo); S=$(fresh_tmpdir); M=$(fresh_tmpdir)
[ -n "$R" ] && [ -n "$S" ] && [ -n "$M" ] || { bad "temp dirs"; exit 1; }
export GAUNTLET_PASS_DIR="$M/pass" GAUNTLET_PASS_CACHE=1 LEVELS_MARK="$M"
g() { git -C "$R" "$@"; }

mkdir -p "$R/scripts/_lib" "$R/tests/_lib" "$R/tests/scripts" "$R/skills/meta/harness-audit/scripts" "$R/src"
cp "$ROOT/scripts/run-gauntlet.sh" "$ROOT/scripts/gauntlet-plan.sh" "$R/scripts/"
for f in gauntlet-lint.sh gauntlet-pass.sh stray-procs.sh lint-files.py; do cp "$ROOT/scripts/_lib/$f" "$R/scripts/_lib/"; done
for f in pipe_into_grep_q.py tmp_delete.py; do cp "$ROOT/tests/_lib/$f" "$R/tests/_lib/"; done
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/scripts/check-observer-contract.sh"
printf '#!/usr/bin/env bash\necho audit >>"$LEVELS_MARK/ran"\n' >"$R/skills/meta/harness-audit/scripts/audit.sh"
for t in a b; do printf '#!/usr/bin/env bash\necho %s >>"$LEVELS_MARK/ran"\n' "$t" >"$R/tests/scripts/test-$t.sh"; done
printf 'src/a.txt medium tests/scripts/test-a.sh\ndocs.md low\n' >"$R/scripts/gauntlet-rules.txt"
echo a >"$R/src/a.txt"; echo d >"$R/docs.md"; echo x >"$R/src/unmapped.txt"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/claude"; chmod +x "$S/claude"
# The lint layer's py_compile leaves __pycache__ behind; untracked, it would keep the full run from recording.
printf '__pycache__/\n' >"$R/.gitignore"
g add .gitignore scripts tests skills src docs.md
g commit -qm base
BASE=$(g rev-parse HEAD)

ran() { if [ -f "$M/ran" ]; then LC_ALL=C sort "$M/ran" | tr '\n' ' '; fi; }
reset() { [ ! -f "$M/ran" ] || tmp_delete "$M/ran"; [ ! -d "$M/pass" ] || tmp_delete "$M/pass"; }
entries() { if [ -d "$M/pass" ]; then find "$M/pass" -type f | wc -l | tr -d ' '; else echo 0; fi; }
gauntlet() { out=$(cd "$R" && PATH="$S:$PATH" bash scripts/run-gauntlet.sh "$@" 2>&1); rc=$?; }

# 7. a medium plan (src/a.txt): only test-a runs, with the audit, and no pass is recorded.
echo a2 >>"$R/src/a.txt"; g commit -qam "src change"
reset; gauntlet --level medium --plan "$BASE"
if [ "$rc" -eq 0 ] && [ "$(ran)" = "a audit " ]; then ok "medium runs only the planned test file, plus the audit"
else bad "medium rc=$rc ran='$(ran)': $out"; fi
if [ "$(entries)" = 0 ]; then ok "a passing medium run records no pass"; else bad "medium wrote $(entries) pass entries"; fi
# Control: the same clean tree, run full, runs both tests and records its pass, so the row above can fail.
reset; gauntlet
if [ "$rc" -eq 0 ] && [ "$(ran)" = "a b " ] && [ "$(entries)" = 1 ]; then ok "control: full on the same tree runs every test and records a pass"
else bad "full control rc=$rc ran='$(ran)' entries=$(entries): $out"; fi
# A higher level than the plan's is fine: full with a plan runs everything.
reset; gauntlet --level full --plan "$BASE"
if [ "$rc" -eq 0 ] && [ "$(ran)" = "a b " ]; then ok "--level full above a medium plan runs the full gauntlet"
else bad "full over medium rc=$rc ran='$(ran)': $out"; fi

# 6. a level below the plan's is refused before anything runs.
reset; gauntlet --level low --plan "$BASE"
if [ "$rc" -eq 2 ] && [ -z "$(ran)" ] && /usr/bin/grep -q 'below the plan' <<<"$out"; then ok "--level low under a medium plan is refused"
else bad "low under medium rc=$rc ran='$(ran)': $out"; fi
echo x2 >>"$R/src/unmapped.txt"; g commit -qam "unmapped change"
reset; gauntlet --level medium --plan "$BASE"
if [ "$rc" -eq 2 ] && [ -z "$(ran)" ] && /usr/bin/grep -q 'src/unmapped.txt is unmapped' <<<"$out"; then
  ok "--level medium under a full plan is refused and names the unmapped path"
else bad "medium under full rc=$rc ran='$(ran)': $out"; fi
reset; gauntlet --level medium
if [ "$rc" -eq 2 ] && [ -z "$(ran)" ]; then ok "--level medium without --plan is refused"; else bad "no plan rc=$rc: $out"; fi

# low on a docs-only plan lints and runs no tests.
D=$(g rev-parse HEAD); echo d2 >>"$R/docs.md"; g commit -qam docs
reset; gauntlet --level low --plan "$D"
if [ "$rc" -eq 0 ] && [ -z "$(ran)" ] && /usr/bin/grep -q '^PASS  lint' <<<"$out"; then ok "low on a docs plan lints only"
else bad "low docs rc=$rc ran='$(ran)': $out"; fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
