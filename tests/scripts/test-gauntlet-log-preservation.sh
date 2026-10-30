#!/usr/bin/env bash
# test-gauntlet-log-preservation.sh — regression for GH #158: a flaky gauntlet
# failure's log must survive so it can be diagnosed, and the printed output
# must be the full failing layer, not a 40-line tail that can hide an earlier
# failure (run_hook_tests() reported PASS-only tails while the real failure
# scrolled off the top, per #158's own repro).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$ROOT/scripts/_lib/tmp-delete.sh"
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
# trash "" resolves to the cwd and deletes it (documented repo incident) — a
# test that mktemp's off its own output must never pass an unchecked result.
safe_tmp_delete() { [ -n "${1:-}" ] && tmp_delete "$1"; return 0; }

echo "=== gauntlet log preservation on failure (GH #158) ==="

TRAP_CMD=$(sed -n "s/^trap '\(.*\)' EXIT\$/\1/p" "$GAUNTLET" | head -1)
if [ -z "$TRAP_CMD" ]; then
  bad "run-gauntlet.sh has no top-level EXIT trap to extract"
else
  ok "extracted EXIT trap command"

  PASS_LOG=$(mktemp -d)
  ( LOG="$PASS_LOG"; fail=0; : "$LOG"; eval "trap '$TRAP_CMD' EXIT" )
  if [ -d "$PASS_LOG" ]; then
    bad "log dir survived a passing run (should be trashed): $PASS_LOG"
    safe_tmp_delete "$PASS_LOG"
  else
    ok "log dir is cleaned up after a passing run (fail=0)"
  fi

  FAIL_LOG=$(mktemp -d)
  ( LOG="$FAIL_LOG"; fail=1; : "$LOG"; eval "trap '$TRAP_CMD' EXIT" )
  if [ -d "$FAIL_LOG" ]; then
    ok "log dir survives a failing run (fail=1), not silently trashed"
  else
    bad "log dir was trashed even though fail=1 (original #158 gap)"
  fi
  safe_tmp_delete "$FAIL_LOG"
fi

# report() must print the whole failing layer's log, not tail -n 40 — a
# real failure earlier than the last 40 lines must not be hidden.
REPORT_BODY=$(sed -n '/^report()/,/^}/p' "$GAUNTLET")
if [ -z "$REPORT_BODY" ]; then
  bad "could not extract report() from run-gauntlet.sh"
else
  LOGDIR=$(mktemp -d)
  printf 'marker-line-%02d\n' $(seq 1 50) >"$LOGDIR/tests"
  out=$(cd "$ROOT" && bash -c "
    LOG=$LOGDIR
    fail=0
    $REPORT_BODY
    # pid 0 is not a job report() can wait on, so 'wait 0' errors and
    # report() takes its FAIL branch, printing \$LOGDIR/tests in full.
    report tests 0
    false
  " 2>&1 || true)
  safe_tmp_delete "$LOGDIR"
  # Count every fixture line, not just one marker: a partial print (e.g. only
  # the first or last line) would pass a single-marker check while still
  # dropping most of the failing layer.
  matched=$(printf '%s\n' "$out" | /usr/bin/grep -c '^      marker-line-')
  if [ "$matched" -eq 50 ]; then
    ok "report() prints all 50 lines of the failing log, not a 40-line tail"
  else
    bad "report() printed $matched/50 fixture lines (tail -n 40 regression or truncation)"
  fi
fi

# A failed `mktemp -d` (GNU mktemp honours a bad TMPDIR; a full /tmp) must stop
# the run before any layer writes to "$LOG/<name>" with LOG empty, i.e. to
# /validate. Extract the LOG assignment line (same style as the trap check
# above -- running the whole gauntlet here would recurse into this test) and
# eval it with a failing mktemp shimmed on PATH: the line must exit non-zero
# and name mktemp, never fall through with LOG empty.
LOG_LINE=$(/usr/bin/grep -m1 '^LOG="\$(mktemp -d)"' "$GAUNTLET")
SHIM=$(mktemp -d)
if [ -z "$LOG_LINE" ]; then
  bad "run-gauntlet.sh has no top-level LOG=\"\$(mktemp -d)\" line to extract"
elif [ -z "$SHIM" ]; then
  bad "mktemp -d failed for the shim dir"
else
  printf '#!/bin/sh\nexit 1\n' > "$SHIM/mktemp"
  chmod +x "$SHIM/mktemp"
  out=$(PATH="$SHIM:$PATH" bash -c "set -uo pipefail; $LOG_LINE; echo \"fell-through LOG=<\$LOG>\"" 2>&1)
  rc=$?
  safe_tmp_delete "$SHIM"
  if [ "$rc" -ne 0 ] && /usr/bin/grep -q 'mktemp' <<<"$out" \
     && ! /usr/bin/grep -q 'fell-through' <<<"$out"; then
    ok "a failed mktemp -d aborts before any layer can use an empty LOG (rc=$rc)"
  else
    bad "a failed mktemp -d did not abort (rc=$rc): $(printf '%s' "$out" | tr '\n' '|')"
  fi
fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
