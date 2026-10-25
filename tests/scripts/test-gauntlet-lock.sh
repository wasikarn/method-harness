#!/usr/bin/env bash
# test-gauntlet-lock.sh — GH #158: scripts/_lib/gauntlet-lock.sh queues pre-push gauntlets so
# only one runs per machine (timing rows fail when several run at once). Each case runs the
# library in its own `bash -c` process, so every case has its own $$, against a throwaway lock
# dir. Fail-open by design: a wait that outlasts GAUNTLET_LOCK_WAIT_SECS proceeds with a message.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
LIB="$HERE/../../scripts/_lib/gauntlet-lock.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet-lock: one gauntlet per machine (GH #158) ==="

source "$HERE/../_lib/harness.sh"
trap _cleanup_trash EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-lock.XXXXXX") || exit 1
track_trash "$T"
BG=""
cleanup_bg() { [ -n "$BG" ] && kill $BG 2>/dev/null; return 0; }
trap 'cleanup_bg; _cleanup_trash' EXIT

L="$T/lock"
# run <snippet>: source the library in a fresh process with fast polling and a short wait cap.
run() {
  GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.1 GAUNTLET_LOCK_WAIT_SECS="${WAIT:-1}" \
    bash -c ". '$LIB'; $1" 2>&1
}
reset() { [ -d "$L" ] && { rm -f "$L/pid"; rmdir "$L"; }; return 0; }

# 1. free lock: acquired by this process, removed on release.
out=$(run 'gauntlet_lock_acquire; echo "mine=$$ pid=$(cat "$GAUNTLET_LOCK_DIR/pid")"; gauntlet_lock_release; [ -e "$GAUNTLET_LOCK_DIR" ] && echo STILL-THERE || echo GONE')
mine=$(printf '%s\n' "$out" | sed -n 's/^mine=\([0-9]*\) pid=.*/\1/p')
pidf=$(printf '%s\n' "$out" | sed -n 's/^mine=[0-9]* pid=\([0-9]*\)$/\1/p')
if [ -n "$mine" ] && [ "$mine" = "$pidf" ]; then ok "a free lock is taken and records this process's pid"; else bad "pid file not this process: $out"; fi
if /usr/bin/grep -q '^GONE$' <<<"$out"; then ok "release removes the lock"; else bad "lock left behind: $out"; fi

# 2. held by a live process: wait out the cap, then fail open with a message and leave the
# holder's lock alone.
sleep 30 & BG=$!
mkdir "$L"; echo "$BG" > "$L/pid"
out=$(WAIT=1 run 'gauntlet_lock_acquire; echo "rc=$?"; gauntlet_lock_release')
if /usr/bin/grep -q 'rc=0' <<<"$out" && /usr/bin/grep -qi 'without the lock' <<<"$out"; then
  ok "a wait past the cap proceeds (fail open) and says so"
else bad "no fail-open message: $out"; fi
if [ "$(cat "$L/pid" 2>/dev/null)" = "$BG" ]; then ok "a fail-open run leaves the live holder's lock alone"; else bad "holder's lock was touched: $(cat "$L/pid" 2>/dev/null)"; fi
if /usr/bin/grep -q 'waiting' <<<"$out"; then ok "the waiter announces that it is waiting"; else bad "no waiting message: $out"; fi

# 3. reentrant: a child of the lock holder (a test that runs the pre-push hook) must not queue.
start=$(date +%s)
out=$(MH_GAUNTLET_LOCK_OWNER="$BG" WAIT=20 run 'gauntlet_lock_acquire; echo "rc=$?"; gauntlet_lock_release')
elapsed=$(( $(date +%s) - start ))
if /usr/bin/grep -q 'rc=0' <<<"$out" && [ "$elapsed" -lt 10 ] && [ "$(cat "$L/pid")" = "$BG" ]; then
  ok "a child of the holder skips the queue and leaves the lock"
else bad "reentrant acquire waited ${elapsed}s or touched the lock: $out"; fi
kill $BG 2>/dev/null; wait $BG 2>/dev/null; BG=""
reset

# 4. stale lock (owner process is gone): reclaimed at once.
dead=$(bash -c 'echo $$')
mkdir "$L"; echo "$dead" > "$L/pid"
start=$(date +%s)
out=$(WAIT=20 run 'gauntlet_lock_acquire; echo "mine=$$ pid=$(cat "$GAUNTLET_LOCK_DIR/pid")"; gauntlet_lock_release')
elapsed=$(( $(date +%s) - start ))
mine=$(printf '%s\n' "$out" | sed -n 's/^mine=\([0-9]*\) pid=.*/\1/p')
pidf=$(printf '%s\n' "$out" | sed -n 's/^mine=[0-9]* pid=\([0-9]*\)$/\1/p')
if [ -n "$mine" ] && [ "$mine" = "$pidf" ] && [ "$elapsed" -lt 10 ]; then ok "a lock whose owner is gone is reclaimed at once"; else bad "stale lock not reclaimed (${elapsed}s): $out"; fi
reset

# 5. a lock dir with no pid file that is old enough is also reclaimed (a crash between mkdir and write).
mkdir "$L"; touch -t 202601010000 "$L"
out=$(WAIT=20 GAUNTLET_LOCK_NOPID_SECS=60 run 'gauntlet_lock_acquire; echo "rc=$?"; gauntlet_lock_release')
if /usr/bin/grep -q 'rc=0' <<<"$out" && ! /usr/bin/grep -qi 'without the lock' <<<"$out"; then ok "an old lock dir with no pid file is reclaimed"; else bad "old pid-less lock not reclaimed: $out"; fi
reset

# 6. queueing: a waiter gets the lock after the holder releases, and says it waited.
# Handshake, not a fixed hold: the holder keeps the lock until the waiter has said "waiting"
# (a fixed 2 s hold could end before a loaded machine had started the waiter's bash).
bash -c ". '$LIB'; GAUNTLET_LOCK_DIR='$L' gauntlet_lock_acquire; i=0; while [ ! -e '$T/go' ] && [ \$i -lt 300 ]; do sleep 0.05; i=\$((i+1)); done; GAUNTLET_LOCK_DIR='$L' gauntlet_lock_release" >/dev/null 2>&1 &
BG=$!
# Start the waiter only once the holder really holds the lock, or it could win the race and never wait.
for _ in $(seq 1 100); do [ -f "$L/pid" ] && break; sleep 0.1; done
WAIT=30 run 'gauntlet_lock_acquire; echo "mine=$$ pid=$(cat "$GAUNTLET_LOCK_DIR/pid")"; gauntlet_lock_release' >"$T/q.out" & W=$!
for _ in $(seq 1 300); do /usr/bin/grep -q 'waiting' "$T/q.out" 2>/dev/null && break; sleep 0.05; done
touch "$T/go"; wait $W; out=$(cat "$T/q.out")
mine=$(printf '%s\n' "$out" | sed -n 's/^mine=\([0-9]*\) pid=.*/\1/p')
pidf=$(printf '%s\n' "$out" | sed -n 's/^mine=[0-9]* pid=\([0-9]*\)$/\1/p')
if [ -n "$mine" ] && [ "$mine" = "$pidf" ] && /usr/bin/grep -q 'waiting' <<<"$out"; then
  ok "a waiter takes the lock after the holder releases"
else bad "waiter did not get its turn: $out"; fi
wait $BG 2>/dev/null; BG=""
if [ ! -e "$L" ]; then ok "no lock is left after both runs"; else bad "lock left behind after the queue drained"; fi

# 7. a lock dir that cannot be created (read-only parent) fails open at once; it must not
# pretend another gauntlet is running and wait out the whole cap.
RO="$T/ro"; mkdir "$RO"; chmod 555 "$RO"
if [ ! -w "$RO" ]; then
  start=$(date +%s)
  out=$(GAUNTLET_LOCK_DIR="$RO/lock" GAUNTLET_LOCK_POLL=0.1 GAUNTLET_LOCK_WAIT_SECS=30 \
    bash -c ". '$LIB'; gauntlet_lock_acquire; echo \"rc=\$?\"; gauntlet_lock_release" 2>&1)
  elapsed=$(( $(date +%s) - start ))
  if /usr/bin/grep -q 'rc=0' <<<"$out" && [ "$elapsed" -lt 10 ] \
    && /usr/bin/grep -qi 'cannot create' <<<"$out" && ! /usr/bin/grep -q 'another gauntlet' <<<"$out"; then
    ok "an uncreatable lock dir fails open at once and says why"
  else bad "uncreatable lock dir stalled ${elapsed}s or blamed another gauntlet: $out"; fi
else
  echo "  SKIP: read-only parent is still writable (running as root?)"
fi
chmod 755 "$RO"

# 8. under the hook's `set -euo pipefail`, a decimal-comma locale must not turn the jittered
# sleep into "sleep: invalid time interval" and kill the push; the wait fails open instead.
if [ "$(LC_ALL=de_DE.UTF-8 awk 'BEGIN { printf "%.1f", 1.5 }' 2>/dev/null)" = "1,5" ]; then
  sleep 30 & BG=$!
  mkdir "$L"; echo "$BG" > "$L/pid"
  # A logging sleep first on PATH: the library hides sleep's stderr and falls back to `sleep 1`,
  # so the only way to see a comma interval is to record what it was asked to sleep.
  mkdir "$T/bin"; : >"$T/sleeps"
  printf '#!/bin/sh\necho "$1" >>"%s/sleeps"\nexec /bin/sleep "$1"\n' "$T" >"$T/bin/sleep"; chmod +x "$T/bin/sleep"
  out=$(PATH="$T/bin:$PATH" LC_ALL=de_DE.UTF-8 GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.2 GAUNTLET_LOCK_WAIT_SECS=2 \
    bash -c "set -euo pipefail; . '$LIB'; gauntlet_lock_acquire; echo rc=\$?" 2>&1)
  if /usr/bin/grep -q 'rc=0' <<<"$out" && ! /usr/bin/grep -qi 'invalid time interval' <<<"$out" \
    && [ -s "$T/sleeps" ] && ! /usr/bin/grep -q ',' "$T/sleeps"; then
    ok "a decimal-comma locale does not break the wait under set -e"
  else bad "locale broke the jittered sleep: $out"; fi
  kill $BG 2>/dev/null; wait $BG 2>/dev/null; BG=""
  reset
else
  echo "  SKIP: no decimal-comma locale (de_DE.UTF-8) on this machine"
fi

# 9. under `set -e`, stray files in the lock dir must not turn a passing run into exit 1, at
# release or when reclaiming a stale lock.
out=$(GAUNTLET_LOCK_DIR="$L" bash -c "set -euo pipefail; . '$LIB'; gauntlet_lock_acquire; touch \"\$GAUNTLET_LOCK_DIR/extra\"; gauntlet_lock_release; echo done" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '^done$' <<<"$out" && [ ! -e "$L" ]; then ok "release with a stray file in the lock dir still exits 0 and clears the lock"; else bad "release broke under set -e (rc=$rc, lock present=$([ -e "$L" ] && echo y || echo n)): $out"; reset; fi
dead=$(bash -c 'echo $$')
mkdir "$L"; echo "$dead" > "$L/pid"; touch "$L/extra"
out=$(GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.1 GAUNTLET_LOCK_WAIT_SECS=20 bash -c "set -euo pipefail; . '$LIB'; gauntlet_lock_acquire; echo rc=\$?; gauntlet_lock_release" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'rc=0' <<<"$out" && ! /usr/bin/grep -qi 'without the lock' <<<"$out"; then ok "a stale lock with a stray file is reclaimed under set -e"; else bad "stale reclaim broke under set -e (rc=$rc): $out"; fi
reset
for d in "$T"/lock.stale.* "$T"/lock.reclaim; do [ -e "$d" ] && bad "leftover $d"; done

# 10. mutual exclusion while reclaiming a stale lock: six racers all find the same dead owner.
# Every round must keep at most one of them inside the critical section.
overlaps=0
for _ in 1 2 3 4 5 6 7 8; do
  rm -f "$T/race.log"
  dead=$(bash -c 'echo $$')
  mkdir "$L"; echo "$dead" > "$L/pid"
  pids=""
  for _ in 1 2 3 4 5 6; do
    GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.02 GAUNTLET_LOCK_WAIT_SECS=60 \
      bash -c ". '$LIB'; gauntlet_lock_acquire; echo in >> '$T/race.log'; sleep 0.1; echo out >> '$T/race.log'; gauntlet_lock_release" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  wait $pids
  o=$(awk '/^in/ { d++; if (d > 1) n++ } /^out/ { d-- } END { print n + 0 }' "$T/race.log")
  overlaps=$((overlaps + o))
  reset
done
if [ "$overlaps" -eq 0 ]; then ok "six racers on a stale lock never overlap (8 rounds)"; else bad "$overlaps overlapping entries while reclaiming a stale lock"; fi

# 11. a stale lock that cannot be emptied (a subdirectory) must not spin past the wait cap, and a
# non-numeric cap or max-age must not break the wait or let a waiter take a live holder's lock.
mkdir "$L"; echo 999999 >"$L/pid"; mkdir "$L/sub"
start=$(date +%s)
out=$(WAIT=1 run 'gauntlet_lock_acquire; echo rc=$?')
elapsed=$(( $(date +%s) - start ))
if /usr/bin/grep -q 'rc=0' <<<"$out" && [ "$elapsed" -le 6 ]; then
  ok "a lock that cannot be removed still fails open at the cap (${elapsed}s)"
else bad "stuck lock spun or stalled (${elapsed}s): $out"; fi
rm -f "$L/pid"; rmdir "$L/sub" "$L" 2>/dev/null; reset

sleep 30 & BG=$!
mkdir "$L"; echo "$BG" > "$L/pid"
out=$(GAUNTLET_LOCK_MAX_AGE=1h GAUNTLET_LOCK_WAIT_SECS=1 GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.1 \
  bash -c ". '$LIB'; gauntlet_lock_acquire; echo owner=\$(cat '$L/pid')" 2>&1)
if /usr/bin/grep -q "owner=$BG" <<<"$out"; then ok "a non-numeric MAX_AGE does not let a waiter take a live lock"
else bad "live lock taken with MAX_AGE=1h: $out"; fi
# WAIT_SECS=2s falls back to the 1800 s default, so it must keep waiting quietly, not error each poll.
GAUNTLET_LOCK_WAIT_SECS=2s GAUNTLET_LOCK_DIR="$L" GAUNTLET_LOCK_POLL=0.1 \
  bash -c ". '$LIB'; gauntlet_lock_acquire" >"$T/ws.out" 2>&1 & W=$!
sleep 3
kill -0 $W 2>/dev/null && alive=yes || alive=no
kill $W 2>/dev/null; wait $W 2>/dev/null
if [ "$alive" = yes ] && ! /usr/bin/grep -q 'integer expected' "$T/ws.out"; then ok "a non-numeric WAIT_SECS falls back to the default without errors"
else bad "WAIT_SECS=2s: alive=$alive $(cat "$T/ws.out")"; fi
kill $BG 2>/dev/null; wait $BG 2>/dev/null; BG=""
reset

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
