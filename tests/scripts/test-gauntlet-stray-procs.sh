#!/usr/bin/env bash
# test-gauntlet-stray-procs.sh — GH #158: scripts/_lib/stray-procs.sh names the operator's own
# long-running CPU-heavy processes (a leftover `yes` flood held the load at ~6 for 4 h on
# 2026-10-25 and failed every push's timing rows). Each case sources the library in a fresh
# `bash -c` and replaces its ps/load readers with fixture text, so no row depends on real CPU time.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
LIB="$HERE/../../scripts/_lib/stray-procs.sh"
GAUNTLET="$HERE/../../scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== stray-procs: name leftover CPU-heavy processes (GH #158) ==="

# pid etime %cpu command, as `ps -o pid=,etime=,%cpu=,command=` prints them.
ROWS='82797     04:27:19  99.4 yes
 1234   1-00:00:30  85.0 /usr/bin/python3 stress.py --n 4
 2222        30:00 250.0 node build
 3333        00:30 100.0 yes
 4444     05:00:00   2.0 /bin/zsh
 5555        29:59  99.0 yes'

# run <ps-body> [env...]: report on stdout+stderr, then "rc=<n>".
run() {
  local body=$1; shift
  env "$@" ROWS="$ROWS" bash -c ". '$LIB'
_sp_ps() { $body; }
_sp_load() { echo 6.25; }
stray_procs_report; echo \"rc=\$?\"" 2>&1
}

out=$(run 'printf "%s\n" "$ROWS"')
case "$out" in *"pid 82797"*"04:27:19"*"yes"*) ok "a 4 h process at 99% is named with pid, elapsed and command" ;; *) bad "4 h yes not named: $out" ;; esac
case "$out" in *"pid 1234"*"stress.py --n 4"*) ok "a dd-hh:mm:ss elapsed counts its days (1-00:00:30 is past 1800 s), and the full command line is kept" ;; *) bad "1-day row missing: $out" ;; esac
case "$out" in *"pid 2222"*) ok "exactly the minimum age and %CPU above 100 (multi-core) count" ;; *) bad "boundary row missing: $out" ;; esac
case "$out" in *"pid 3333"*) bad "a 30 s process was named: $out" ;; *) ok "a 30 s process is not named" ;; esac
case "$out" in *"pid 4444"*) bad "a 2% process was named: $out" ;; *) ok "a long but idle process is not named" ;; esac
case "$out" in *"pid 5555"*) bad "a 29:59 process was named: $out" ;; *) ok "one second under the minimum age is not named" ;; esac
case "$out" in *"load 6.25"*) ok "the warning states the load average" ;; *) bad "load missing: $out" ;; esac
case "$out" in *"rc=0") ok "it returns 0 even when it finds strays (a warning, never a gate)" ;; *) bad "non-zero rc: $out" ;; esac

out=$(env ROWS="$ROWS" bash -c ". '$LIB'; _sp_ps() { printf '%s\n' \"\$ROWS\"; }; stray_procs_report" 2>/dev/null)
[ -z "$out" ] && ok "the warning goes to stderr, never stdout (a caller may capture stdout)" || bad "stdout got: $out"

out=$(run 'printf "%s\n" " 3333 00:30 100.0 yes"')
[ "$out" = "rc=0" ] && ok "no strays: silent, rc 0" || bad "no-stray run printed: $out"

out=$(run 'return 1')
[ "$out" = "rc=0" ] && ok "ps failing: silent, rc 0" || bad "ps failure printed: $out"

out=$(run 'printf "%s\n" "$ROWS"' GAUNTLET_STRAY_MIN_SECS=20 GAUNTLET_STRAY_MIN_CPU=1)
case "$out" in *"pid 3333"*"pid 4444"*|*"pid 4444"*"pid 3333"*) ok "GAUNTLET_STRAY_MIN_SECS / _MIN_CPU lower the thresholds" ;; *) bad "env thresholds ignored: $out" ;; esac

out=$(run 'printf "%s\n" "$ROWS"' GAUNTLET_STRAY_MIN_SECS=1h GAUNTLET_STRAY_MIN_CPU=x)
case "$out" in *"pid 3333"*|*"pid 4444"*) bad "a non-numeric threshold changed the result: $out" ;; *"pid 82797"*) ok "a non-numeric threshold falls back to the default" ;; *) bad "fallback run lost the 4 h row: $out" ;; esac

out=$(bash -ec ". '$LIB'; _sp_ps() { return 1; }; stray_procs_report; echo after" 2>&1)
[ "$out" = "after" ] && ok "a set -e caller is not aborted" || bad "set -e caller aborted: $out"

# Wiring: the gauntlet reports before its layers and again on failure. Text check only; running
# the gauntlet from a gauntlet test would recurse.
n=$(/usr/bin/grep -c 'stray_procs_report' "$GAUNTLET")
[ "$n" -ge 2 ] && ok "run-gauntlet.sh calls stray_procs_report before the layers and on failure" || bad "run-gauntlet.sh calls it $n time(s)"

echo "stray-procs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
