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
for f in gauntlet-lint.sh gauntlet-pass.sh gauntlet-progress.sh stray-procs.sh lint-files.py tmp-delete.sh tmp_delete.py; do cp "$ROOT/scripts/_lib/$f" "$R/scripts/_lib/"; done
cp "$ROOT/tests/_lib/pipe_into_grep_q.py" "$R/tests/_lib/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/scripts/check-observer-contract.sh"
printf '#!/usr/bin/env bash\necho audit >>"$LEVELS_MARK/ran"\n' >"$R/skills/meta/harness-audit/scripts/audit.sh"
# test-b fails under LEVELS_FAIL=1 (GH #814: a failing step); each records what GAUNTLET_PROGRESS it saw.
for t in a b; do printf '#!/usr/bin/env bash\necho %s >>"$LEVELS_MARK/ran"\necho "${GAUNTLET_PROGRESS-unset}" >>"$LEVELS_MARK/progress-env"\n' "$t" >"$R/tests/scripts/test-$t.sh"; done
printf '[ -z "${LEVELS_FAIL:-}" ] || { echo "  FAIL: forced"; exit 1; }\n' >>"$R/tests/scripts/test-b.sh"
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

# GH #814: live progress. On (GAUNTLET_PROGRESS=1), each run's progress ends at its own total, computed before
# any step: full 4 (validate, lint, 2 tests), low on docs 1 (lint), medium 4 (validate, lint, audit, 1 test), and
# the two shards' totals sum to 4. Unset with the output captured (no TTY), no progress line at all.
prog_end() { /usr/bin/grep -E '^gauntlet: [0-9]+/[0-9]+ steps finished' <<<"$out" | sed 's/ steps finished.*//; s/^gauntlet: //'; }
H=$(g rev-parse HEAD)
reset; out=$(cd "$R" && PATH="$S:$PATH" GAUNTLET_PROGRESS=1 bash scripts/run-gauntlet.sh 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(prog_end)" = 4/4 ]; then ok "progress on: a full run ends at 4/4"; else bad "full progress rc=$rc end='$(prog_end)': $out"; fi
if [ "$(sort -u "$M/progress-env")" = unset ]; then ok "a test file never sees GAUNTLET_PROGRESS"; else bad "tests saw: $(sort -u "$M/progress-env" | tr '\n' ' ')"; fi
reset; echo d3 >>"$R/docs.md"; g commit -qam docs2
out=$(cd "$R" && PATH="$S:$PATH" GAUNTLET_PROGRESS=1 bash scripts/run-gauntlet.sh --level low --plan "$H" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(prog_end)" = 1/1 ]; then ok "progress on: low on docs ends at 1/1"; else bad "low progress rc=$rc end='$(prog_end)': $out"; fi
H=$(g rev-parse HEAD); echo a3 >>"$R/src/a.txt"; g commit -qam src3
reset; out=$(cd "$R" && PATH="$S:$PATH" GAUNTLET_PROGRESS=1 bash scripts/run-gauntlet.sh --level medium --plan "$H" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(prog_end)" = 4/4 ]; then ok "progress on: medium with one planned test ends at 4/4"; else bad "medium progress rc=$rc end='$(prog_end)': $out"; fi
sum=0
for sh in 1/2 2/2; do
  reset; out=$(cd "$R" && PATH="$S:$PATH" GAUNTLET_PROGRESS=1 GAUNTLET_SHARD=$sh bash scripts/run-gauntlet.sh 2>&1)
  e=$(prog_end); [ "${e%/*}" = "${e#*/}" ] || bad "shard $sh progress ends at '$e'"; sum=$((sum + ${e#*/}))
done
if [ "$sum" = 4 ]; then ok "progress on: the shard totals sum to 4"; else bad "shard totals sum to $sum"; fi
reset; gauntlet
if [ "$rc" -eq 0 ] && ! /usr/bin/grep -q '^gauntlet: \[' <<<"$out" && ! /usr/bin/grep -q 'steps finished' <<<"$out"; then
  ok "progress unset and captured (no TTY): no progress line"; else bad "unset progress printed: $out"; fi
# A failing step: the same exit code as with progress off, a FAIL progress line, and the failing: list still last.
reset; out=$(cd "$R" && PATH="$S:$PATH" LEVELS_FAIL=1 GAUNTLET_PROGRESS=1 bash scripts/run-gauntlet.sh 2>&1); rc_on=$?
last=$(tail -n 1 <<<"$out")
reset; out_off=$(cd "$R" && PATH="$S:$PATH" LEVELS_FAIL=1 GAUNTLET_PROGRESS=0 bash scripts/run-gauntlet.sh 2>&1); rc_off=$?
if [ "$rc_on" -ne 0 ] && [ "$rc_on" = "$rc_off" ]; then ok "a failing step keeps the exit code with progress on ($rc_on)"; else bad "rc on=$rc_on off=$rc_off"; fi
if /usr/bin/grep -qE '^gauntlet: \[ *[0-9]+/4 +[0-9]+%\] FAIL  tests/scripts/test-b\.sh \([0-9]+s, rc 1\)$' <<<"$out"; then ok "a failing step gets a FAIL progress line with its code"
else bad "no FAIL progress line: $out"; fi
if [ "$last" = "failing: tests/scripts/test-b.sh" ]; then ok "with progress on, the last line is still the failing: list (GH #387)"; else bad "last line: '$last'"; fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
