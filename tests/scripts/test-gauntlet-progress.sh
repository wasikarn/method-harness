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
( sleep 1; printf 'S a\nE 0 1 a\n' >>"$prog"; printf 'S b\nE 1 2 b\n' >>"$prog"; printf 'S c\nE 0 0 c\n' >>"$prog" ) & w=$!
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
