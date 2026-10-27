#!/usr/bin/env bash
# test-gauntlet-failed-summary.sh — regression for GH #387: a red gauntlet run
# must name the failing test files. CI logs ran to 3284 lines with 49 sections
# and no line said which file failed. Pulls run_hook_tests() out of the script
# (same style as test-gauntlet-log-preservation.sh) with hook_test_files()
# stubbed to two fixtures, one passing and one failing; never runs the gauntlet.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && python3 "$ROOT/tests/_lib/tmp_delete.py" "$1"; return 0; }

echo "=== gauntlet names failing test files (GH #387) ==="

BODY=$(sed -n '/^run_hook_tests()/,/^}/p' "$GAUNTLET")
FIX=$(mktemp -d)
if [ -z "$BODY" ]; then
  bad "could not extract run_hook_tests() from run-gauntlet.sh"
elif [ -z "$FIX" ]; then
  bad "mktemp -d failed for the fixture dir"
else
  printf 'exit 0\n' >"$FIX/test-green.sh"
  printf 'echo "  ✅ fine row"\necho "  ❌ GH #307 allow shape finishes inside 8 s (rc 124)"\necho "=== 1 passed, 1 failed ==="\nexit 1\n' >"$FIX/test-red.sh"
  out=$(bash -c "
    $BODY
    hook_test_files() { printf '%s\n' '$FIX/test-green.sh' '$FIX/test-red.sh'; }
    run_hook_tests
  " 2>&1)
  rc=$?
  line=$(printf '%s\n' "$out" | /usr/bin/grep '^failing:')
  if [ "$rc" -ne 0 ]; then
    ok "layer still exits non-zero when a file fails (rc=$rc)"
  else
    bad "layer exited 0 with a failing file"
  fi
  if /usr/bin/grep -qF "$FIX/test-red.sh" <<<"$line"; then
    ok "a 'failing:' line names the failing file"
  else
    bad "no 'failing:' line naming $FIX/test-red.sh; got: <$line>"
  fi
  if /usr/bin/grep -qF "test-green.sh" <<<"$line"; then
    bad "the 'failing:' line also names the passing file: <$line>"
  else
    ok "the 'failing:' line leaves out the passing file"
  fi
  # GH #158: the failing row itself, so a load flake reads differently from a regression.
  at=$(printf '%s\n' "$out" | /usr/bin/grep '^failed-at:')
  if /usr/bin/grep -qF "test-red.sh" <<<"$at" && /usr/bin/grep -qF 'finishes inside 8 s (rc 124)' <<<"$at"; then
    ok "a 'failed-at:' line names the failing file and its failing row"
  else
    bad "no 'failed-at:' line with the failing row; got: <$at>"
  fi
  if /usr/bin/grep -qF "fine row" <<<"$at"; then
    bad "the 'failed-at:' line includes a passing row: <$at>"
  else
    ok "the 'failed-at:' line leaves out passing rows"
  fi
fi
safe_trash "$FIX"

# The final FAILED message is the tail of a CI log, so it must repeat the list
# from the tests layer's log. Run the script's closing if-block on a fixture LOG.
TAIL=$(sed -n '/^if \[ "\$fail" -eq 0 \]/,/^fi/p' "$GAUNTLET")
LOGDIR=$(mktemp -d)
if [ -z "$TAIL" ]; then
  bad "could not extract the closing if-block from run-gauntlet.sh"
elif [ -z "$LOGDIR" ]; then
  bad "mktemp -d failed for the log dir"
else
  printf -- '--- tests/x.sh\nnoise\nfailed-at: tests/scripts/test-red.sh: ❌ row\nfailing: tests/scripts/test-red.sh\n' >"$LOGDIR/tests"
  # stray_procs_report reads the real ps; a stub stands in, and its line proves the call runs.
  out=$(bash -c "LOG='$LOGDIR'; fail=1; stray_procs_report() { echo 'gauntlet: warning: stub'; }; $TAIL" 2>&1)
  stub_at=$(printf '%s\n' "$out" | /usr/bin/grep -n -m1 -F 'gauntlet: warning: stub' | cut -d: -f1)
  list_at=$(printf '%s\n' "$out" | /usr/bin/grep -n -m1 '^failing:' | cut -d: -f1)
  if [ -n "$stub_at" ] && [ -n "$list_at" ] && [ "$stub_at" -lt "$list_at" ]; then
    ok "a failed run reports stray processes, above the failing: list (GH #158)"
  else
    bad "no stray report above the failing: list (stub line '$stub_at', failing: line '$list_at'): <$out>"
  fi
  last=$(printf '%s\n' "$out" | tail -n 1)
  if /usr/bin/grep -qF 'failing: tests/scripts/test-red.sh' <<<"$last"; then
    ok "the last line of a failed run repeats the failing: list"
  else
    bad "the last line of a failed run does not name the file: <$last>"
  fi
  if /usr/bin/grep -qF 'failed-at: tests/scripts/test-red.sh: ❌ row' <<<"$out"; then
    ok "a failed run repeats the failed-at: rows above the failing: list"
  else
    bad "a failed run does not repeat the failed-at: rows: <$out>"
  fi
fi
# Deep-audit: three passing rows that mention FAIL must not push the real failing row out of the 3 shown.
FIX=$(mktemp -d)
printf 'echo "  ✅ PASS: rejects FAIL one"\necho "  ✅ PASS: rejects FAIL two"\necho "  ✅ PASS: rejects FAIL three"\necho "  ❌ real regression row"\nexit 1\n' >"$FIX/test-red.sh"
out2=$(bash -c "
  $BODY
  hook_test_files() { printf '%s\n' '$FIX/test-red.sh'; }
  run_hook_tests
" 2>&1)
if /usr/bin/grep -q '^failed-at:.*real regression row' <<<"$out2"; then
  ok "failed-at keeps the failing row when passing rows also say FAIL"
else
  bad "failed-at hid the failing row behind passing rows: <$out2>"
fi
safe_trash "$FIX"
safe_trash "$LOGDIR"

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
