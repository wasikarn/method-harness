#!/usr/bin/env bash
# Unit tests for hooks/sensors/qmd-first-nudge.{sh,py}.
# Advisory PostToolUse(WebSearch | qmd) sensor: never blocks (always exit 0); nudges once, on the
# first WebSearch of a session with no earlier qmd call and `qmd` on PATH; logs one row per session.
# Run standalone: bash tests/hooks/test-qmd-first-nudge.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
SENSOR="$ROOT/hooks/sensors/qmd-first-nudge.sh"
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

WORK=$(mktemp -d)
trap '[ -n "$WORK" ] && tmp_delete "$WORK"' EXIT
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/qmd"
chmod +x "$WORK/bin/qmd"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
export MH_QMD_FIRST_LOG="$WORK/log.jsonl"

payload() { # tool session
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": sys.argv[1], "session_id": sys.argv[2], "tool_input": {}}))' "$1" "$2"
}
run() { # tool session [extra PATH dir]
  payload "$1" "$2" | PATH="${3:-$WORK/bin}:$PATH" bash "$SENSOR"
}
rows() { [ -f "$MH_QMD_FIRST_LOG" ] && wc -l < "$MH_QMD_FIRST_LOG" | tr -d ' ' || echo 0; }

# 1. WebSearch with no earlier qmd call nudges once, exit 0, one log row (nudged true).
out=$(run WebSearch s1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'mh-qmd-first-nudge' \
   && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]=="PostToolUse" and d["additionalContext"]'; then
  ok "first WebSearch, no qmd before it -- nudge emitted as PostToolUse additionalContext"
else
  bad "expected a nudge, got rc=$rc out='$out'"
fi
[ "$(rows)" = 1 ] && grep -q '"qmd_before_web": false' "$MH_QMD_FIRST_LOG" && grep -q '"nudged": true' "$MH_QMD_FIRST_LOG" \
  && ok "one log row: qmd_before_web false, nudged true" || bad "log row wrong: $(cat "$MH_QMD_FIRST_LOG" 2>&1)"

# 2. A second WebSearch in the same session stays silent and adds no row.
out=$(run WebSearch s1)
[ -z "$out" ] && [ "$(rows)" = 1 ] && ok "second WebSearch same session -- silent, no new row" || bad "second WebSearch should be silent: '$out' rows=$(rows)"

# 3. qmd first, then WebSearch: silent, row says compliant.
out=$(run mcp__plugin_qmd_qmd__query s2); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "qmd call alone -- silent, exit 0" || bad "qmd call should be silent: rc=$rc out='$out'"
out=$(run WebSearch s2)
if [ -z "$out" ] && [ "$(rows)" = 2 ] && tail -1 "$MH_QMD_FIRST_LOG" | grep -q '"qmd_before_web": true'; then
  ok "qmd before WebSearch -- no nudge, row logs qmd_before_web true"
else
  bad "qmd-first session should not nudge: out='$out' rows=$(rows)"
fi

# 4. No qmd binary on PATH: no nudge, but the row is still logged (nudged false).
mkdir -p "$WORK/empty"
out=$(payload WebSearch s3 | env PATH="$WORK/empty:/usr/bin:/bin" bash "$SENSOR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && tail -1 "$MH_QMD_FIRST_LOG" | grep -q '"nudged": false'; then
  ok "no qmd binary -- no nudge, row logged with nudged false"
else
  bad "no-binary case: rc=$rc out='$out' row=$(tail -1 "$MH_QMD_FIRST_LOG")"
fi

# 5. Sessions are independent.
out=$(run WebSearch s4)
printf '%s' "$out" | grep -q 'mh-qmd-first-nudge' && ok "a new session gets its own nudge" || bad "new session should nudge: '$out'"

# 6. Other tools, other events and junk input are ignored; exit 0 always.
for t in Bash Read mcp__plugin_context7_context7__query-docs; do
  out=$(run "$t" s5); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || bad "tool $t should be ignored: rc=$rc out='$out'"
done
ok "unrelated tools ignored"
out=$(printf 'not json' | bash "$SENSOR"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "malformed stdin -- silent, exit 0" || bad "malformed stdin: rc=$rc out='$out'"
out=$(python3 -c 'import json; print(json.dumps({"tool_name": "WebSearch", "session_id": "../evil"}))' | PATH="$WORK/bin:$PATH" bash "$SENSOR" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$WORK/evil" ] && ok "unsafe session_id -- no nudge, nothing written outside the marker dir" || bad "unsafe session id: rc=$rc out='$out'"

# 7. Unwritable log: still exits 0 and still nudges.
MH_QMD_FIRST_LOG="/dev/null/x/log.jsonl" out=$(run WebSearch s6 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'mh-qmd-first-nudge' && ok "unwritable log -- fails open, still nudges" || bad "unwritable log: rc=$rc out='$out'"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
