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
if [ "$rc" -eq 0 ] && grep -q 'mh-qmd-first-nudge' <<<"$out" \
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
if [ -z "$out" ] && [ "$(rows)" = 2 ] && grep -q '"qmd_before_web": true' <<<"$(tail -1 "$MH_QMD_FIRST_LOG")"; then
  ok "qmd before WebSearch -- no nudge, row logs qmd_before_web true"
else
  bad "qmd-first session should not nudge: out='$out' rows=$(rows)"
fi

# 4. No qmd binary on PATH: no nudge, but the row is still logged (nudged false).
mkdir -p "$WORK/empty"
out=$(payload WebSearch s3 | env PATH="$WORK/empty:/usr/bin:/bin" bash "$SENSOR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '"nudged": false' <<<"$(tail -1 "$MH_QMD_FIRST_LOG")"; then
  ok "no qmd binary -- no nudge, row logged with nudged false"
else
  bad "no-binary case: rc=$rc out='$out' row=$(tail -1 "$MH_QMD_FIRST_LOG")"
fi

# 5. Sessions are independent.
out=$(run WebSearch s4)
grep -q 'mh-qmd-first-nudge' <<<"$out" && ok "a new session gets its own nudge" || bad "new session should nudge: '$out'"

# 6. Other tools, other events and junk input are ignored; exit 0 always.
ignored_bad=0
for t in Bash Read WebFetch mcp__plugin_context7_context7__query-docs; do
  out=$(run "$t" s5); rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$out" ]; then bad "tool $t should be ignored: rc=$rc out='$out'"; ignored_bad=1; fi
done
[ "$ignored_bad" = 0 ] && [ "$(rows)" = 4 ] && ok "unrelated tools ignored, no row written" || bad "ignored tools wrote a row or nudged (rows=$(rows))"
out=$(python3 -c 'import json; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "WebSearch", "session_id": "s5b"}))' | PATH="$WORK/bin:$PATH" bash "$SENSOR"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows)" = 4 ] && ok "a non-PostToolUse event is ignored" || bad "PreToolUse event: rc=$rc out='$out' rows=$(rows)"
out=$(printf 'not json' | bash "$SENSOR"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "malformed stdin -- silent, exit 0" || bad "malformed stdin: rc=$rc out='$out'"
before=$(find "$TMPDIR" | wc -l | tr -d ' ')
out=$(python3 -c 'import json; print(json.dumps({"tool_name": "WebSearch", "session_id": "../evil"}))' | PATH="$WORK/bin:$PATH" bash "$SENSOR" 2>/dev/null); rc=$?
after=$(find "$TMPDIR" | wc -l | tr -d ' ')
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$before" = "$after" ] && [ "$(rows)" = 4 ] && ok "unsafe session_id -- no nudge, no marker, no row" || bad "unsafe session id: rc=$rc out='$out' files $before->$after rows=$(rows)"
out=$(python3 -c 'import json; print(json.dumps({"tool_name": "WebSearch", "session_id": "s7", "agent_id": "../x"}))' | PATH="$WORK/bin:$PATH" bash "$SENSOR" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows)" = 4 ] && ok "unsafe agent_id -- no nudge, no row" || bad "unsafe agent id: rc=$rc out='$out' rows=$(rows)"

# 7. Unwritable log: still exits 0 and still nudges.
out=$(MH_QMD_FIRST_LOG="/dev/null/x/log.jsonl" run WebSearch s6 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -q 'mh-qmd-first-nudge' <<<"$out" && ok "unwritable log -- fails open, still nudges" || bad "unwritable log: rc=$rc out='$out'"

# 8. The Firecrawl connector's search counts as a web search.
out=$(run mcp__claude_ai_Firecrawl__firecrawl_search s8)
grep -q 'mh-qmd-first-nudge' <<<"$out" && ok "Firecrawl search first -- nudged" || bad "Firecrawl search should nudge: '$out'"

# 9. A subagent's search is its own thread: it is nudged and does not use up the main thread's nudge.
agent_run() { # tool session agent
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": sys.argv[1], "session_id": sys.argv[2], "agent_id": sys.argv[3]}))' "$1" "$2" "$3" | PATH="$WORK/bin:$PATH" bash "$SENSOR"
}
out=$(agent_run WebSearch s9 ag1)
grep -q 'mh-qmd-first-nudge' <<<"$out" && ok "subagent first search -- nudged" || bad "subagent should be nudged: '$out'"
out=$(run WebSearch s9)
grep -q 'mh-qmd-first-nudge' <<<"$out" && ok "main thread still nudged after its subagent was" || bad "main thread should keep its own nudge: '$out'"
grep -q '"subagent": true' "$MH_QMD_FIRST_LOG" && ok "log row marks the subagent thread" || bad "no subagent row in log"

# 10. A subagent's qmd call counts for the whole session.
agent_run mcp__plugin_qmd_qmd__query s10 ag2 >/dev/null
out=$(run WebSearch s10)
[ -z "$out" ] && ok "subagent qmd call before the main thread's search -- no nudge" || bad "subagent qmd should count: '$out'"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
