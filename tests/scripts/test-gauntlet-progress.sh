#!/usr/bin/env bash
# test-gauntlet-progress.sh — GH #814: run-gauntlet.sh's live progress (scripts/_lib/gauntlet-progress.sh).
# Sources the lib and drives it on fixture events and background pids; never runs a gauntlet. The fixture
# gauntlet runs (full, medium, low, shards, a failing step) are in test-gauntlet-levels.sh.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet progress: totals, modes, layers, watcher, heartbeat (GH #814) ==="

LIB="$ROOT/scripts/_lib/gauntlet-progress.sh"
[ -f "$LIB" ] || { bad "missing $LIB"; echo "self-test: $pass passed, $fail failed"; exit 1; }
# shellcheck source=../../scripts/_lib/gauntlet-progress.sh
. "$LIB"
T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || { bad "mktemp -d"; exit 1; }
trap '[ -n "$T" ] && tmp_delete "$T"' EXIT

# 1. totals per level and shard
check_total() { local got; got=$(progress_total "$1" "$2" "$3"); [ "$got" = "$4" ] && ok "progress_total $1 '${2}' $3 = $4" || bad "progress_total $1 '${2}' $3: got '$got', want $4"; }
check_total low "" 0 1
check_total medium "" 11 14
check_total medium "" 0 3
check_total full "" 90 92
check_total full 1/4 1 3
check_total full 2/4 29 29
# shard totals add up to the unsharded total: 43 + 47 test files split over 2 shards, 2 layers in shard 1
s=$(( $(progress_total full 1/2 43) + $(progress_total full 2/2 47) ))
[ "$s" = "$(progress_total full "" 90)" ] && ok "shard totals sum to the unsharded total ($s)" || bad "shard totals sum to $s"

# 2. on or off
on() { ( prog_mode=$1; progress_on ) 2>"$T/stderr-file"; }
on 1 && ok "GAUNTLET_PROGRESS=1 is on" || bad "1 is not on"
if on 0; then bad "0 is on"; else ok "GAUNTLET_PROGRESS=0 is off"; fi
if on auto; then bad "auto with stderr to a file is on"; else ok "auto with stderr to a file is off"; fi
if on yes; then bad "an unknown value with stderr to a file is on"; else ok "an unknown value is auto (off here)"; fi

# 3. progress_layer: output to $LOG/<name>, S and E events, the command's exit code
LOG="$T/log"; mkdir -p "$LOG"; prog="$LOG/progress"; : >"$prog"
progress_layer lint bash -c 'echo lint-out; exit 0'; r0=$?
progress_layer audit bash -c 'echo audit-out; exit 3'; r3=$?
[ "$r0" = 0 ] && [ "$r3" = 3 ] && ok "progress_layer returns the command's exit code (0, 3)" || bad "progress_layer codes $r0 $r3"
[ "$(cat "$LOG/lint")" = lint-out ] && [ "$(cat "$LOG/audit")" = audit-out ] && ok "progress_layer sends output to \$LOG/<name>" \
  || bad "layer output: $(cat "$LOG/lint" "$LOG/audit" 2>&1)"
ev=$(awk '{ print $1, ($1 == "E" ? $2 " " $4 : $2) }' "$prog" | tr '\n' ';')
[ "$ev" = "S lint;E 0 lint;S audit;E 3 audit;" ] && ok "progress_layer writes S and E events with the code" || bad "events: $ev"

# 4. the watcher: count, percent, FAIL with its code, a total that rises, the finished line
: >"$prog"
( sleep 1; printf 'S a\nE 0 1 a\nS b\nE 1 2 b\nS c\nE 0 0 c\n' >>"$prog" ) & w=$!  # one write: no tick between
out=$(prog_beat=60 progress_watch 2 "$w" "" 2>&1 >/dev/null); wait "$w"
printf '%s\n' "$out" >"$T/watch"
/usr/bin/grep -qxF 'gauntlet: 2 steps' "$T/watch" && ok "header names the step count" || bad "no header: $out"
/usr/bin/grep -qxF 'gauntlet: [1/2  50%] PASS  a (1s)' "$T/watch" && ok "PASS line with count, percent and duration" || bad "no PASS a line: $out"
/usr/bin/grep -qxF 'gauntlet: [2/2 100%] FAIL  b (2s, rc 1)' "$T/watch" && ok "FAIL line names the exit code" || bad "no FAIL b line: $out"
/usr/bin/grep -qxF 'gauntlet: [3/3 100%] PASS  c (0s)' "$T/watch" && ok "an extra step raises the total, never past 100%" || bad "no raised total: $out"
[ "$(tail -n 1 "$T/watch" | sed 's/ in .*//')" = 'gauntlet: 3/3 steps finished' ] && ok "ends with N/N steps finished" || bad "last line: $(tail -n 1 "$T/watch")"

# 5. heartbeat: a started step with no end, a pid still running
: >"$prog"; printf 'S tests/hooks/test-slow.sh\n' >>"$prog"
sleep 3 & w=$!
out=$(timeout 20 bash -c '. "$1"; prog=$2; prog_beat=1; progress_watch 5 "$3"' _ "$LIB" "$prog" "$w" 2>&1); rc=$?
wait "$w" 2>/dev/null
printf '%s\n' "$out" >"$T/beat"
[ "$rc" = 0 ] && ok "the watcher returns once its pids exit (rc $rc)" || bad "watcher rc=$rc (124 is a hang)"
/usr/bin/grep -qE '^gauntlet: \[0/5   0%\] running tests/hooks/test-slow\.sh [0-9]+s \([0-9]+s elapsed\)$' "$T/beat" \
  && ok "a heartbeat names the step still running" || bad "no heartbeat: $out"

# 5b. review: a step name with a space leaves the running list when it ends (the heartbeat no longer names it)
: >"$prog"; printf 'S tests/a b.sh\nE 0 2 tests/a b.sh\nS tests/slow.sh\n' >>"$prog"
sleep 3 & w=$!
out=$(timeout 20 bash -c '. "$1"; prog=$2; prog_beat=1; progress_watch 5 "$3"' _ "$LIB" "$prog" "$w" 2>&1); wait "$w" 2>/dev/null
if /usr/bin/grep -q 'running tests/slow\.sh' <<<"$out" && ! /usr/bin/grep -q 'running.*tests/a' <<<"$out"; then
  ok "a finished step whose name has a space leaves the running list"; else bad "running list: $out"; fi
# 5c. review: an events path that cannot be written prints nothing and changes no code
out=$( (prog=/nonexistent-gh814/dir/p; progress_event S x; echo "rc=$?") 2>&1)
[ "$out" = "rc=0" ] && ok "an unwritable events path prints nothing" || bad "unwritable events path printed: $out"

# 5d. review (F1): bash drops a finished background job's saved status when a later fork of the same shell
# reuses its pid, so report()'s `wait "$pN"` could read the fork's code: a failing layer read as passing. Every
# watcher fork must come from one subshell forked while the layers still run. The script check holds everywhere;
# the pid-reuse rows need to set the next pid (root, /proc/sys/kernel/ns_last_pid) and say SKIP otherwise.
G="$ROOT/scripts/run-gauntlet.sh"
blk=$(sed -n '/^if progress_on; then$/,/^fi$/p' "$G")
body=$(sed '1d;$d' <<<"$blk")
outside=$(sed '/^if progress_on; then$/,/^fi$/d' "$G" | /usr/bin/grep -v '^ *#' | /usr/bin/grep -cE 'progress_watch|progress_total|hook_test_files \| awk')
if [ -n "$body" ] && [[ "$(head -n 1 <<<"$body")" =~ ^[[:space:]]*\( ]] && [[ "$(tail -n 1 <<<"$body")" =~ \)[[:space:]]*$ ]] \
  && /usr/bin/grep -q progress_watch <<<"$body" && [ "$outside" = 0 ]; then
  ok "run-gauntlet.sh runs the watcher and its counting only inside one ( subshell )"
else bad "watcher block: <$blk>, calls outside it: $outside"; fi
NS=/proc/sys/kernel/ns_last_pid
if [ -w "$NS" ]; then
  r=$(bash -c '( exit 3 ) & p=$!; sleep 1; echo $((p - 1)) >"$1"; x=$(:); wait "$p"; echo $?' _ "$NS")
  if [ "$r" != 3 ]; then ok "control: a main-shell fork on a finished layer's pid changes its wait code (got $r)"
  else echo "  SKIP: this kernel did not hand out the forced pid; the reuse row proves nothing here"; fi
  r=$(bash -c '. "$1"; prog=$3; : >"$prog"; ( sleep 1; exit 3 ) & p=$!
    ( sleep 2; echo $((p - 1)) >"$2"; x=$(:); prog_beat=60 progress_watch 1 "$p" ) 2>/dev/null
    wait "$p"; echo $?' _ "$LIB" "$NS" "$T/reuse-events")
  [ "$r" = 3 ] && ok "a fork in the watcher subshell on a finished layer's pid keeps the layer's code (3)" || bad "wait read $r, not 3"
else echo "  SKIP: pid-reuse rows need a writable $NS (root on Linux)"; fi

# 6. durations
[ "$(_progress_dur 59)" = 59s ] && [ "$(_progress_dur 192)" = 3m12s ] && [ "$(_progress_dur 3600)" = 60m00s ] \
  && ok "durations read Ns, then NmSSs" || bad "durations: $(_progress_dur 59) $(_progress_dur 192) $(_progress_dur 3600)"

# 7. no cursor codes, and no line a caller parses: failing:, failed-at:, PASS  , FAIL  , SKIP
if /usr/bin/grep -q $'\r\|\033' "$T/watch" "$T/beat"; then bad "a progress line holds \\r or ESC"; else ok "no \\r or ESC in progress output"; fi
if /usr/bin/grep -qE '^(failing:|failed-at:|PASS  |FAIL  |SKIP  )' "$T/watch" "$T/beat"; then
  bad "a progress line starts with a prefix callers parse"
else ok "no progress line starts with failing:, failed-at:, PASS, FAIL or SKIP"; fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
