#!/usr/bin/env bash
# test-gauntlet-stray-procs.sh — GH #158: scripts/_lib/stray-procs.sh names the operator's own
# long-running CPU-heavy process groups. Two real floods drive the rows: 4 `yes` at 100% CPU for
# ~4 h (2026-10-25) and 289 stress workers at load ~248, about 4% each on 12 cores (2026-10-05).
# Each case sources the library in a fresh `bash -c` and replaces its ps/load readers with fixture
# text, so no row depends on real CPU time; the last rows run the real readers against PATH shims.
set -uo pipefail
# An operator may set these in settings.json env; the rows below assume the defaults.
unset GAUNTLET_STRAY_MIN_SECS GAUNTLET_STRAY_MIN_CPU
HERE="$(cd -P "$(dirname "$0")" && pwd)"
LIB="$HERE/../../scripts/_lib/stray-procs.sh"
GAUNTLET="$HERE/../../scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
source "$HERE/../_lib/harness.sh"
trap _cleanup_trash EXIT

echo "=== stray-procs: name leftover CPU-heavy process groups (GH #158) ==="

# pid etime %cpu command, as `ps -o pid=,etime=,%cpu=,command=` prints them.
ROWS='82797     04:27:19  99.4 yes
82799     04:27:19  99.0 yes
 1234   1-00:00:30  85.0 /usr/bin/python3 stress.py --n 4
 2222        30:00 250.0 node build
 3333        00:30 100.0 yes
 4444     05:00:00   2.0 /bin/zsh
 5555        29:59  99.0 sleeper
 6666     01:00:00  80.0 exact80
 7777     01:00:00  79.9 under80'
# The Claude desktop app runs all day, its helpers summing 341% CPU on 2026-10-26: an app's own
# processes are not a stray run. A build tool shipped inside an app bundle (Xcode's) still is.
ROWS="$ROWS
 7801  01-17:41:36  90.0 /Applications/Claude.app/Contents/MacOS/Claude
 7802  01-17:41:33 200.0 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer
 7803  01-05:41:54  51.2 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process
 7804     04:00:00  99.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
 7901     01:00:00 150.0 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme App
 7902     04:00:00  99.0 /opt/homebrew/Cellar/python@3.15/3.15.1/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python /tmp/fuzz.py
 7903     02:00:00  95.0 $HOME/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude -p run"
for i in $(seq 1 30); do ROWS="$ROWS
 $((9000 + i))        45:00   4.0 /tmp/racer.sh"; done
for i in $(seq 1 43); do ROWS="$ROWS
 $((8000 + i))     05:00:00   0.0 /usr/libexec/SetStoreUpdateService"; done

# run <ps-body> [env...]: report on stdout+stderr, then "rc=<n>".
run() {
  local body=$1; shift
  env "$@" ROWS="$ROWS" bash -c ". '$LIB'
_sp_ps() { $body; }
_sp_load() { echo 6.25; }
stray_procs_report; echo \"rc=\$?\"" 2>&1
}
line() { printf '%s\n' "$out" | /usr/bin/grep "^  $1:"; }

out=$(run 'printf "%s\n" "$ROWS"')
l=$(line yes)
case "$l" in *"2 processes"*"pids 82797 82799"*) ok "two 4 h yes at 99% are one group with both pids" ;; *) bad "yes group wrong: <$l> in $out" ;; esac
case "$l" in *3333*) bad "a 30 s yes joined the old yes group: <$l>" ;; *) ok "a young copy of the same command is left out of the group" ;; esac
case "$(line python3)" in *"1 process"*"pids 1234"*"stress.py --n 4"*) ok "a dd-hh:mm:ss elapsed counts its days (1-00:00:30), and the command line is shown" ;; *) bad "1-day row missing: $out" ;; esac
case "$(line node)" in *"pids 2222"*) ok "exactly the minimum age and %CPU above 100 (multi-core) count" ;; *) bad "boundary age row missing: $out" ;; esac
case "$(line exact80)" in *"pids 6666"*) ok "exactly the minimum %CPU counts" ;; *) bad "80.0% row missing: $out" ;; esac
case "$out" in *under80*) bad "a 79.9% process was named: $out" ;; *) ok "just under the minimum %CPU is not named" ;; esac
case "$(line racer.sh)" in *"30 processes at 120"*) ok "30 workers at 4% each sum to one named group (the 2026-10-05 flood shape)" ;; *) bad "low-CPU flood not named: $out" ;; esac
case "$out" in *SetStoreUpdateService*) bad "43 idle copies were named: $out" ;; *) ok "many idle copies of one command are not named" ;; esac
case "$out" in *zsh*) bad "a 2% process was named: $out" ;; *) ok "a long but idle process is not named" ;; esac
case "$out" in *Claude:*|*Google*) bad "a desktop app's own processes were named: $out" ;; *) ok "an /Applications app's own executables are not named, a bundle name with a space included" ;; esac
case "$(line xcodebuild)" in *"pids 7901"*) ok "a build tool inside an app bundle (Contents/Developer) is still named" ;; *) bad "xcodebuild row missing: $out" ;; esac
case "$(line Python)" in *"pids 7902"*) ok "a framework python3 run (it re-execs through Python.app/Contents/MacOS) is still named" ;; *) bad "Homebrew Python row missing: $out" ;; esac
case "$(line claude)" in *"pids 7903"*) ok "a long headless claude CLI run (ClaudeCode.app outside /Applications) is still named" ;; *) bad "claude CLI row missing: $out" ;; esac
case "$out" in *sleeper*) bad "a 29:59 process was named: $out" ;; *) ok "one second under the minimum age is not named" ;; esac
case "$out" in *"load 6.25"*) ok "the warning states the load average" ;; *) bad "load missing: $out" ;; esac
case "$out" in *"rc=0") ok "it returns 0 even when it finds strays (a warning, never a gate)" ;; *) bad "non-zero rc: $out" ;; esac

out=$(env ROWS="$ROWS" bash -c ". '$LIB'; _sp_ps() { printf '%s\n' \"\$ROWS\"; }; stray_procs_report" 2>/dev/null)
[ -z "$out" ] && ok "the warning goes to stderr, never stdout (a caller may capture stdout)" || bad "stdout got: $out"

out=$(run 'printf "%s\n" " 3333 00:30 100.0 yes"')
[ "$out" = "rc=0" ] && ok "no strays: silent, rc 0" || bad "no-stray run printed: $out"

out=$(run 'return 1')
case "$out" in "gauntlet: stray-process check skipped (ps failed)"*"rc=0") ok "ps failing: one diagnostic line, rc 0" ;; *) bad "ps failure not reported: $out" ;; esac

out=$(env ROWS="$ROWS" bash -c ". '$LIB'; _sp_ps() { printf '%s\n' \"\$ROWS\"; }; _sp_load() { return 1; }; stray_procs_report" 2>&1)
case "$out" in *"load unknown"*) ok "a failing load reader prints 'load unknown', not an empty value" ;; *) bad "empty load: $out" ;; esac

out=$(run 'printf "%s\n" "$ROWS"' GAUNTLET_STRAY_MIN_SECS=20 GAUNTLET_STRAY_MIN_CPU=1)
case "$(line yes)" in *"3 processes"*) ok "GAUNTLET_STRAY_MIN_SECS lowers the age threshold" ;; *) bad "env age ignored: $out" ;; esac
case "$(line zsh)" in *"pids 4444"*) ok "GAUNTLET_STRAY_MIN_CPU lowers the CPU threshold" ;; *) bad "env cpu ignored: $out" ;; esac

out=$(run 'printf "%s\n" "$ROWS"' GAUNTLET_STRAY_MIN_SECS=1h GAUNTLET_STRAY_MIN_CPU=x)
case "$out" in *zsh*|*"3 processes"*) bad "a non-numeric threshold changed the result: $out" ;; *"pids 82797"*) ok "a non-numeric threshold falls back to the default" ;; *) bad "fallback run lost the yes group: $out" ;; esac

out=$(bash -ec ". '$LIB'; _sp_ps() { return 1; }; stray_procs_report; echo after" 2>/dev/null)
[ "$out" = "after" ] && ok "a set -e caller is not aborted when ps fails" || bad "set -e caller aborted: $out"

out=$(env ROWS="$ROWS" bash -ec ". '$LIB'; _sp_ps() { printf '%s\n' \"\$ROWS\"; }; _sp_load() { return 1; }; stray_procs_report; echo after" 2>/dev/null)
[ "$out" = "after" ] && ok "a set -e caller is not aborted when strays are found and the load reader fails" || bad "set -e caller aborted on a load failure: $out"

# The real readers, through PATH shims instead of overridden helpers. The ps shim acts like macOS
# ps where the report depends on it: an unknown -o keyword (say `etimes`, which macOS lacks) is an
# error, columns come out in the order -o asks for, no -o gives the default PID TTY TIME CMD
# columns under a header, and it lists rows only for `-U <your uid>`.
SHIM=$(fresh_tmpdir)
[ -n "$SHIM" ] && [ -d "$SHIM" ] || { echo "FAIL: fresh_tmpdir gave no shim dir" >&2; exit 1; }
cat >"$SHIM/ps" <<EOF
#!/bin/bash
uid="" cols=""
while [ \$# -gt 0 ]; do
  case "\$1" in -U) uid=\$2; shift 2 ;; -o) cols=\$2; shift 2 ;; *) shift ;; esac
done
for c in \${cols//,/ }; do
  case "\$c" in pid=|etime=|%cpu=|command=) ;; *) echo "ps: \${c%=}: keyword not found" >&2; exit 1 ;; esac
done
[ "\$uid" = "$(id -u)" ] || exit 0
row() {
  if [ -z "\$cols" ]; then echo "\$1 ttys000    0:01.00 \$4"; return; fi
  local out="" c
  for c in \${cols//,/ }; do
    case "\$c" in pid=) out="\$out \$1" ;; etime=) out="\$out \$2" ;; %cpu=) out="\$out \$3" ;; command=) out="\$out \$4" ;; esac
  done
  echo "\$out"
}
[ -n "\$cols" ] || echo "  PID TTY           TIME CMD"
row 82797 04:27:19 99.4 yes
row 82799 04:27:19 99.0 yes
EOF
printf '#!/bin/bash\necho "10:00  up 3 days,  2:00, 2 users, load averages: 3.21 2.00 1.00"\n' >"$SHIM/uptime"
chmod +x "$SHIM/ps" "$SHIM/uptime"
out=$(PATH="$SHIM:$PATH" bash -c ". '$LIB'; stray_procs_report" 2>&1)
case "$out" in *"yes: 2 processes"*"pids 82797 82799"*) ok "the real ps call (-U uid, -o pid=,etime=,%cpu=,command=) feeds the report" ;; *) bad "real ps call did not feed the report: $out" ;; esac
case "$out" in *"load 3.21;"*) ok "the real load reader parses macOS uptime ('load averages: 3.21 2.00 1.00')" ;; *) bad "macOS uptime not parsed: $out" ;; esac
printf '#!/bin/bash\necho " 10:00:00 up 3 days,  2:00,  1 user,  load average: 4.56, 2.00, 1.00"\n' >"$SHIM/uptime"
out=$(PATH="$SHIM:$PATH" bash -c ". '$LIB'; stray_procs_report" 2>&1)
case "$out" in *"load 4.56;"*) ok "the real load reader parses Linux uptime ('load average: 4.56, 2.00, 1.00')" ;; *) bad "Linux uptime not parsed: $out" ;; esac

# Wiring: the gauntlet reports before it starts the layers (the failure-path call and its place
# above the failing: list are covered by test-gauntlet-failed-summary.sh). Text check only;
# running the gauntlet from a gauntlet test would recurse.
first=$(/usr/bin/grep -n -m1 '^stray_procs_report' "$GAUNTLET" | cut -d: -f1)
layers=$(/usr/bin/grep -n -m1 'run_hook_tests >"\$LOG/tests"' "$GAUNTLET" | cut -d: -f1)  # inside the --level branches (GH #749)
if [ -n "$first" ] && [ -n "$layers" ] && [ "$first" -lt "$layers" ]; then
  ok "run-gauntlet.sh calls stray_procs_report before it starts the layers"
else
  bad "no stray_procs_report call before the layers start (call line '$first', layers line '$layers')"
fi

echo "stray-procs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
