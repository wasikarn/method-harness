#!/usr/bin/env bash
# Unit tests for hooks/sensors/failure-diagnose-nudge.{sh,py} (GH #153).
# Advisory PostToolUseFailure(Bash) sensor: never blocks (always exit 0), emits a
# diagnose-before-retry nudge on a real Bash failure, capped at 1 per distinct
# command per session.
# Run standalone: bash tests/hooks/test-failure-diagnose-nudge.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SENSOR="$ROOT/hooks/sensors/failure-diagnose-nudge.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# A PostToolUse(Bash)-success-shaped payload -- used only as a "wrong shape"
# fixture below (hooks.json no longer routes this event to the sensor at
# all, deep-audit 2026-09-07, but is_failure() must still stay false-safe on
# any shape that isn't PostToolUseFailure).
posttooluse_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "tool_response": {"exit_code": int(sys.argv[2])}}))' "$1" "$2"
}

# The REAL shape of a failing Bash call, per the installed Claude Code binary's
# own hook-input schema (Ioe in the 2.1.263 bundle): PostToolUseFailure has NO
# tool_response field at all -- exit_code never appears anywhere in it. It has
# hook_event_name, tool_name, tool_input, tool_use_id, and error (a string).
# Deep-audit 2026-09-07: PostToolUse(Bash) never fires for a real nonzero
# shell exit in this CC version -- confirmed by a live in-session debug dump
# that never received a single invocation on a genuine `ls <missing-path>`
# failure. This is the only shape hooks.json now routes to the sensor.
posttoolusefailure_payload() {
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "tool_use_id": "toolu_test", "error": sys.argv[2]}))' "$1" "$2"
}

STATE_DIR=$(mktemp -d)
trap '[ -n "$STATE_DIR" ] && trash "$STATE_DIR" 2>/dev/null || true' EXIT
STATE="$STATE_DIR/state.json"

# --- a non-PostToolUseFailure-shaped payload never nudges, regardless of
# its exit_code -- is_failure() keys only off hook_event_name now ---
out=$(posttooluse_payload "ls -la" 0 | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "non-PostToolUseFailure shape (exit 0) -- no nudge, exit 0"
else
  bad "PostToolUse-success shape should produce no output and exit 0, got rc=$rc out='$out'"
fi

out=$(posttooluse_payload "make build" 1 | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "non-PostToolUseFailure shape (exit 1) -- still no nudge, exit 0 (dead PostToolUse branch stays removed)"
else
  bad "PostToolUse-shaped payload should never nudge post-removal, got rc=$rc out='$out'"
fi

# --- the REAL failure shape (PostToolUseFailure, no tool_response/exit_code
# at all) nudges -- this is what a genuine Bash failure sends ---
out=$(posttoolusefailure_payload "make build" "Command failed with exit code 1" | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out"; then
  ok "PostToolUseFailure shape -- nudge emitted, exit 0 (never blocks)"
else
  bad "PostToolUseFailure shape should emit the nudge and exit 0, got rc=$rc out='$out'"
fi
if echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["hookSpecificOutput"]["hookEventName"] == "PostToolUseFailure" else 1)'; then
  ok "PostToolUseFailure payload echoes hookEventName: PostToolUseFailure"
else
  bad "expected hookSpecificOutput.hookEventName == PostToolUseFailure, got: $out"
fi

# --- a user-interrupted command (is_interrupt: true) is not a failure to
# diagnose: no nudge, and it must not spend the command's cap (GH #331) ---
payload=$(posttoolusefailure_payload "interrupted-cmd" "Interrupted by user")
payload=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["is_interrupt"]=True; print(json.dumps(d))' "$payload")
out=$(echo "$payload" | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "is_interrupt: true -- no nudge, exit 0 (GH #331)"
else
  bad "is_interrupt: true should produce no output and exit 0, got rc=$rc out='$out'"
fi
out=$(posttoolusefailure_payload "interrupted-cmd" "Command failed" | bash "$SENSOR" "$STATE")
if /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out"; then
  ok "an interrupt does not spend the command's cap -- a later real failure still nudges"
else
  bad "a real failure after an interrupt of the same command should still nudge, got '$out'"
fi

# --- cap enforcement: same command failing repeatedly stops nudging after CAP=1 ---
trash "$STATE" 2>/dev/null || true
nudge_count=0
for _ in 1 2 3 4 5; do
  out=$(posttoolusefailure_payload "flaky-cmd --retry" "Command failed" | bash "$SENSOR" "$STATE")
  /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out" && nudge_count=$((nudge_count + 1))
done
if [ "$nudge_count" -eq 1 ]; then
  ok "cap enforcement: exactly 1 nudge across 5 identical failures (was uncapped in the trialed plugin)"
else
  bad "expected exactly 1 nudge across 5 identical failures, got $nudge_count"
fi

# --- a DIFFERENT failing command gets its own fresh cap ---
out=$(posttoolusefailure_payload "a-completely-different-command" "Command failed" | bash "$SENSOR" "$STATE")
if /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out"; then
  ok "a different failing command is not affected by another command's exhausted cap"
else
  bad "a fresh distinct command should still nudge even after a different command's cap is exhausted"
fi

# --- unparseable stdin: fail-open, no crash, no nudge ---
out=$(printf 'not json at all' | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "unparseable payload -- fails open silently, exit 0"
else
  bad "unparseable payload should fail open with no output, got rc=$rc out='$out'"
fi

# --- missing python3: fail-open with a stderr announcement (GH #93 posture) ---
# Payload written to a file and redirected (not piped from a live process):
# the sensor's python3-missing fast path never reads stdin at all, so a live
# upstream writer piping into it can hit a benign SIGPIPE race that pollutes
# the captured exit status -- redirecting from a file sidesteps that.
# A directory containing only a `bash` symlink, not a hardcoded OS path: macOS's
# /bin lacks python3 (Apple's stub lives in /usr/bin), but a usr-merged Linux
# distro symlinks /bin -> /usr/bin, so PATH=/bin still finds python3 there --
# confirmed live on Ubuntu 24.04 (readlink -f /bin -> /usr/bin).
STDERR_CAP="$STATE_DIR/stderr.txt"
NO_PYTHON3_PATH="$STATE_DIR/no-python3-bin"
mkdir -p "$NO_PYTHON3_PATH"
ln -sf "$(command -v bash)" "$NO_PYTHON3_PATH/bash"
posttoolusefailure_payload "make build" "Command failed" > "$STATE_DIR/payload.json"
out=$(PATH="$NO_PYTHON3_PATH" bash "$SENSOR" "$STATE" < "$STATE_DIR/payload.json" 2>"$STDERR_CAP")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && /usr/bin/grep -qi 'python3 not found' "$STDERR_CAP"; then
  ok "missing python3 -- fails open AND announces on stderr (GH #93 posture)"
else
  bad "missing python3 should fail open + announce, got rc=$rc out='$out' stderr='$(cat "$STDERR_CAP" 2>/dev/null)'"
fi

# --- default_state_path keys off the payload's own session_id, not just the
# env var -- a missing CLAUDE_CODE_SESSION_ID must not collapse every session
# onto one shared, never-reset counter file ---
FAKE_TMPDIR="$STATE_DIR/tmp-default"
mkdir -p "$FAKE_TMPDIR"
payload=$(posttoolusefailure_payload "default-path-cmd" "Command failed")
payload=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["session_id"]="sess-xyz"; print(json.dumps(d))' "$payload")
out=$(
  unset CLAUDE_CODE_SESSION_ID
  export TMPDIR="$FAKE_TMPDIR"
  echo "$payload" | bash "$SENSOR"
)
rc=$?
expected_state="$FAKE_TMPDIR/mh-sensors/failure-nudge-sess-xyz.json"
if [ "$rc" -eq 0 ] && [ -f "$expected_state" ] && /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out"; then
  ok "default_state_path uses the payload's session_id, staying session-scoped without the env var"
else
  bad "expected state file at $expected_state, got rc=$rc out='$out'"
fi

# --- a session_id that is not a safe file-name part never reaches a path ---
# The id names the counter file, so `x/../../../victim` once wrote outside
# $TMPDIR/mh-sensors (it added a key to victim.json) and an embedded NUL
# crashed the sensor with a traceback. The id goes through the shared
# validate_session_id (scripts/_lib/hook_payload.py); a bad one fails open:
# the nudge still goes out, uncapped, a [mh:sensor] line says why, and no file
# is written anywhere. Only the Claude Code host builds this payload, and it
# sends UUIDs, so this is hardening.
SID_ROOT="$STATE_DIR/sid"
SID_TMP="$SID_ROOT/a/tmp"
mkdir -p "$SID_TMP"
printf '{"keep": 1}' > "$SID_ROOT/a/victim.json"
sid_payload() { # $1 command, $2 session_id as a JSON literal ("" for no key)
  python3 -c '
import json, sys
d = {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
     "tool_input": {"command": sys.argv[1]}, "tool_use_id": "toolu_test", "error": "Command failed"}
if sys.argv[2]:
    d["session_id"] = json.loads(sys.argv[2])
print(json.dumps(d))' "$1" "$2"
}
sid_run() { # $1 command, $2 session_id JSON literal, $3 CLAUDE_CODE_SESSION_ID (empty = unset)
  sid_payload "$1" "$2" > "$STATE_DIR/sid-payload.json"
  if [ -n "$3" ]; then
    out=$(env CLAUDE_CODE_SESSION_ID="$3" TMPDIR="$SID_TMP" bash "$SENSOR" < "$STATE_DIR/sid-payload.json" 2>"$STATE_DIR/sid-err.txt")
  else
    out=$(env -u CLAUDE_CODE_SESSION_ID TMPDIR="$SID_TMP" bash "$SENSOR" < "$STATE_DIR/sid-payload.json" 2>"$STATE_DIR/sid-err.txt")
  fi
  rc=$?
  err=$(cat "$STATE_DIR/sid-err.txt")
}
sid_tree() { (cd "$SID_ROOT" && find . | LC_ALL=C sort && cat a/victim.json); }
i=0
for sid in '"x/../../../victim"' '"a\u0000b"' '""' '["/../../../victim"]' '42' 'null' 'ENV:x/../../../victim'; do
  i=$((i + 1))
  before=$(sid_tree)
  case "$sid" in
    ENV:*) sid_run "bad-sid-cmd-$i" "" "${sid#ENV:}"; label="CLAUDE_CODE_SESSION_ID=${sid#ENV:} (payload has none)" ;;
    *) sid_run "bad-sid-cmd-$i" "$sid" ""; label="session_id $sid" ;;
  esac
  after=$(sid_tree)
  if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out" \
     && /usr/bin/grep -q '\[mh:sensor\]' <<<"$err" \
     && ! /usr/bin/grep -q 'Traceback' <<<"$err" \
     && [ "$after" = "$before" ]; then
    ok "$label -- nudge still sent, [mh:sensor] diagnostic, no traceback, no file written anywhere"
  else
    bad "$label -- expected rc 0 + nudge + [mh:sensor] diagnostic + no traceback + unchanged tree; got rc=$rc out='$out' err='$err' tree diff: $(diff <(echo "$before") <(echo "$after") | tr '\n' ' ')"
  fi
done
UUID="3f2b6c1e-8a4d-4b7e-9c2a-1d5e6f7a8b9c"
sid_run "good-sid-cmd" "\"$UUID\"" ""
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out" \
   && [ -f "$SID_TMP/mh-sensors/failure-nudge-$UUID.json" ] && [ -z "$err" ]; then
  ok "a UUID session_id still gets its own counter file under mh-sensors, no diagnostic"
else
  bad "a UUID session_id should write $SID_TMP/mh-sensors/failure-nudge-$UUID.json silently; got rc=$rc out='$out' err='$err'"
fi
sid_run "good-env-cmd" "" "$UUID-env"
if [ "$rc" -eq 0 ] && [ -f "$SID_TMP/mh-sensors/failure-nudge-$UUID-env.json" ] && [ -z "$err" ]; then
  ok "a valid CLAUDE_CODE_SESSION_ID is still the fallback when the payload has no session_id"
else
  bad "a valid CLAUDE_CODE_SESSION_ID fallback should name the counter file; got rc=$rc err='$err'"
fi
# --- a subagent shares its parent's session_id, so the counter also keys on
# agent_id (GH #463): the parent's spent cap must not silence a subagent, and
# one subagent's cap must not silence another ---
agent_run() { # $1 command, $2 agent_id JSON literal ("" for no key)
  python3 -c '
import json, sys
d = {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "session_id": sys.argv[3],
     "tool_input": {"command": sys.argv[1]}, "tool_use_id": "toolu_test", "error": "Command failed"}
if sys.argv[2]:
    d["agent_id"] = json.loads(sys.argv[2])
print(json.dumps(d))' "$1" "$2" "$UUID" > "$STATE_DIR/agent-payload.json"
  out=$(env -u CLAUDE_CODE_SESSION_ID TMPDIR="$SID_TMP" bash "$SENSOR" < "$STATE_DIR/agent-payload.json" 2>"$STATE_DIR/agent-err.txt")
  rc=$?
  err=$(cat "$STATE_DIR/agent-err.txt")
}
nudged() { /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out"; }
agent_run "shared-cmd" ""
main1=0; nudged && main1=1
agent_run "shared-cmd" ""
main2=0; nudged && main2=1
agent_run "shared-cmd" '"agent-aaa"'
a1=0; nudged && a1=1
agent_run "shared-cmd" '"agent-aaa"'
a2=0; nudged && a2=1
agent_run "shared-cmd" '"agent-bbb"'
b1=0; nudged && b1=1
if [ "$main1$main2$a1$a2$b1" = "10101" ]; then
  ok "counter keys on agent_id: parent, each subagent get one nudge per command, repeats are capped"
else
  bad "expected main/main/aaa/aaa/bbb nudges 1/0/1/0/1, got $main1/$main2/$a1/$a2/$b1"
fi
for aid in 'null' '""' '"x/../../../victim"'; do
  agent_run "bad-agent-cmd-$aid" "$aid"
  if [ "$rc" -eq 0 ] && nudged && /usr/bin/grep -q '\[mh:sensor\]' <<<"$err"; then
    ok "agent_id $aid present but not a safe id -- nudge still sent, [mh:sensor] diagnostic"
  else
    bad "agent_id $aid should fail open with a diagnostic; got rc=$rc out='$out' err='$err'"
  fi
done
# A sensor copy with no scripts/_lib beside it: the validator cannot load, so
# it fails open with a diagnostic and still nudges.
NOLIB="$STATE_DIR/nolib/hooks/sensors"
mkdir -p "$NOLIB"
cp "$ROOT/hooks/sensors/failure-diagnose-nudge.sh" "$ROOT/hooks/sensors/failure-diagnose-nudge.py" "$NOLIB/"
sid_payload "no-lib-cmd" "\"$UUID\"" > "$STATE_DIR/sid-payload.json"
out=$(env -u CLAUDE_CODE_SESSION_ID TMPDIR="$SID_TMP" bash "$NOLIB/failure-diagnose-nudge.sh" < "$STATE_DIR/sid-payload.json" 2>"$STATE_DIR/sid-err.txt")
rc=$?
err=$(cat "$STATE_DIR/sid-err.txt")
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'mh-failure-diagnose-nudge' <<<"$out" \
   && /usr/bin/grep -q '\[mh:sensor\].*cannot load scripts/_lib/hook_payload.py' <<<"$err" \
   && ! /usr/bin/grep -q 'Traceback' <<<"$err"; then
  ok "missing scripts/_lib/hook_payload.py -- nudge still sent, [mh:sensor] diagnostic, no traceback"
else
  bad "missing hook_payload.py should fail open with a diagnostic; got rc=$rc out='$out' err='$err'"
fi

# --- locked() must actually provide mutual exclusion (Deep-audit 2026-09-07:
# load_counts/save_counts used to run as two separate, uncoordinated file
# opens, letting concurrent Bash completions interleave their read-modify-
# write and lose an increment). A natural-timing race across real subprocess
# launches did NOT reliably reproduce the interleave on this machine (process
# fork/exec overhead swamps the actual race window) -- tried and confirmed
# unreliable before writing this, so it is deliberately not the regression
# test. Instead: two child processes each hold locked() for a fixed sleep
# while recording their own [acquire, release] timestamps to a shared file;
# mutual exclusion holds iff neither interval overlaps the other. This is
# deterministic (no timing luck) and tests the actual property the fix
# provides, not a proxy for it.
LOCK_TEST_STATE="$STATE_DIR/lock-test-state.json"
LOCK_TEST_LOG="$STATE_DIR/lock-intervals.jsonl"
python3 - "$ROOT/hooks/sensors/failure-diagnose-nudge.py" "$LOCK_TEST_STATE" "$LOCK_TEST_LOG" <<'PYEOF'
import importlib.util, os, sys, time

sensor_path, state_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fdn", sensor_path)
fdn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fdn)

def hold(tag):
    with fdn.locked(state_path):
        start = time.time()
        time.sleep(0.3)
        end = time.time()
    with open(log_path, "a") as f:
        f.write(f"{tag} {start} {end}\n")

# os.fork() (not multiprocessing.Process) -- macOS's default "spawn" start
# method needs to re-import __main__ from a real file path, which a script
# read from stdin doesn't have.
pids = []
for tag in ("A", "B"):
    pid = os.fork()
    if pid == 0:
        hold(tag)
        os._exit(0)
    pids.append(pid)
for pid in pids:
    os.waitpid(pid, 0)

with open(log_path) as f:
    rows = [line.split() for line in f if line.strip()]
intervals = {tag: (float(s), float(e)) for tag, s, e in rows}
(sa, ea), (sb, eb) = intervals["A"], intervals["B"]
overlap = sa < eb and sb < ea
sys.exit(1 if overlap else 0)
PYEOF
if [ "$?" -eq 0 ]; then
  ok "locked() provides real mutual exclusion: two holders' [acquire, release] intervals never overlap"
else
  bad "locked() failed to serialize -- two holders' intervals overlapped ($(cat "$LOCK_TEST_LOG" 2>/dev/null))"
fi

# --- from the second nudge on in one counter scope, the short text goes out
# (2026-10-22); the first is the full one. Only the tag is pinned, so wording
# can change; "shorter" is the observable contract. ---
SHORT_STATE="$STATE_DIR/short.json"
ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
first=$(posttoolusefailure_payload "false one" "exit 1" | bash "$SENSOR" "$SHORT_STATE" | ctx)
second=$(posttoolusefailure_payload "false two" "exit 1" | bash "$SENSOR" "$SHORT_STATE" | ctx)
case "$first$second" in
  *"<mh-failure-diagnose-nudge>"*"</mh-failure-diagnose-nudge>"*"<mh-failure-diagnose-nudge>"*"</mh-failure-diagnose-nudge>"*)
    if [ "${#second}" -lt "${#first}" ]; then
      ok "first nudge is the full text, the second distinct failure gets the shorter one (${#first} -> ${#second} chars)"
    else
      bad "second nudge should be shorter: first=${#first} second=${#second}"
    fi ;;
  *) bad "both nudges must carry the tag: first='$first' second='$second'" ;;
esac

# --- with no counter file (a session_id that is not a safe file name) every
# nudge is the full text: there is no record that the full one went out ---
sid_run "uncapped full one" '"../x"' ""
u1=$(printf '%s' "$out" | ctx)
sid_run "uncapped full two" '"../x"' ""
u2=$(printf '%s' "$out" | ctx)
if [ -n "$first" ] && [ "$u1" = "$first" ] && [ "$u2" = "$first" ]; then
  ok "uncapped path (no state file) sends the full text every time (${#u1} chars)"
else
  bad "uncapped nudges should equal the full text (${#first} chars): got ${#u1} and ${#u2}"
fi

echo "failure-diagnose-nudge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
