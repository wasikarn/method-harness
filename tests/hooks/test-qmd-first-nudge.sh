#!/usr/bin/env bash
# Unit tests for hooks/sensors/qmd-first-nudge.{sh,py}.
# Advisory PostToolUse sensor on WebSearch, the Firecrawl search and qmd tools: never blocks
# (always exit 0). Nudges once per thread (main or subagent), on the thread's first search when
# no qmd call came earlier in the session and `qmd` is on PATH; logs one row per thread.
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
mkdir -p "$WORK/bin" "$WORK/empty"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/qmd"
chmod +x "$WORK/bin/qmd"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
export MH_QMD_FIRST_LOG="$WORK/log.jsonl"
ERR="$WORK/err.txt"

# payload TOOL SESSION [AGENT] [EVENT]: a hook payload, built in one place.
payload() {
  python3 -c '
import json, sys
tool, session, agent, event = sys.argv[1:5]
d = {"hook_event_name": event or "PostToolUse", "tool_name": tool, "session_id": session}
if agent:
    d["agent_id"] = agent
print(json.dumps(d))' "$1" "$2" "${3:-}" "${4:-}"
}
# run TOOL SESSION [AGENT] [EVENT]: stdout is the sensor's output, stderr lands in $ERR.
run() { payload "$@" | PATH="$WORK/bin:$PATH" bash "$SENSOR" 2>"$ERR"; }
rows() { if [ -f "$MH_QMD_FIRST_LOG" ]; then wc -l < "$MH_QMD_FIRST_LOG" | tr -d ' '; else echo 0; fi; }
last_row() { tail -1 "$MH_QMD_FIRST_LOG"; }
nudged() { grep -q 'mh-qmd-first-nudge' <<<"$1"; }

# 1. First WebSearch, no qmd before it: nudge as PostToolUse additionalContext, one row.
out=$(run WebSearch s1); rc=$?
if [ "$rc" -eq 0 ] && nudged "$out" \
   && python3 -c 'import json,sys; d=json.loads(sys.argv[1])["hookSpecificOutput"]; assert d["hookEventName"]=="PostToolUse" and d["additionalContext"]' "$out"; then
  ok "first WebSearch, no qmd before it -- nudge emitted as PostToolUse additionalContext"
else
  bad "expected a nudge, got rc=$rc out='$out'"
fi
row=$(last_row)
if [ "$(rows)" = 1 ] && grep -q '"qmd_before_web": false' <<<"$row" && grep -q '"nudged": true' <<<"$row" \
   && grep -q '"subagent": false' <<<"$row" && grep -q '"agent_id": null' <<<"$row" \
   && python3 -c 'import json,sys; assert isinstance(json.loads(sys.argv[1])["ts"], float)' "$row"; then
  ok "one log row: qmd_before_web false, nudged true, main thread, millisecond ts"
else
  bad "log row wrong: $row"
fi

# 2. A second WebSearch in the same thread stays silent and adds no row.
out=$(run WebSearch s1)
if [ -z "$out" ] && [ "$(rows)" = 1 ]; then ok "second WebSearch same thread -- silent, no new row"; else bad "second WebSearch should be silent: '$out' rows=$(rows)"; fi

# 3. qmd first, then WebSearch: silent, row says compliant.
out=$(run mcp__plugin_qmd_qmd__query s2); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "qmd call alone -- silent, exit 0"; else bad "qmd call should be silent: rc=$rc out='$out'"; fi
out=$(run WebSearch s2)
if [ -z "$out" ] && [ "$(rows)" = 2 ] && grep -q '"qmd_before_web": true' <<<"$(last_row)"; then
  ok "qmd before WebSearch -- no nudge, row logs qmd_before_web true"
else
  bad "qmd-first session should not nudge: out='$out' rows=$(rows)"
fi

# 4. No qmd binary on PATH: no nudge, but the row is still logged (nudged false).
out=$(payload WebSearch s3 | env PATH="$WORK/empty:/usr/bin:/bin" bash "$SENSOR" 2>"$ERR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '"nudged": false' <<<"$(last_row)"; then
  ok "no qmd binary -- no nudge, row logged with nudged false"
else
  bad "no-binary case: rc=$rc out='$out' row=$(last_row)"
fi

# 5. Sessions are independent.
out=$(run WebSearch s4)
if nudged "$out"; then ok "a new session gets its own nudge"; else bad "new session should nudge: '$out'"; fi

# 6. Other tools and other events are ignored and write nothing.
r0=$(rows); ignored_bad=0
for t in Bash Read WebFetch mcp__plugin_context7_context7__query-docs; do
  out=$(run "$t" s5); rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$out" ]; then bad "tool $t should be ignored: rc=$rc out='$out'"; ignored_bad=1; fi
done
if [ "$ignored_bad" = 0 ] && [ "$(rows)" = "$r0" ]; then ok "unrelated tools (WebFetch included) ignored, no row written"; else bad "ignored tools wrote a row or nudged (rows $r0 -> $(rows))"; fi
out=$(run WebSearch s5b "" PreToolUse); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows)" = "$r0" ]; then ok "a non-PostToolUse event is ignored"; else bad "PreToolUse event: rc=$rc out='$out' rows=$(rows)"; fi

# 7. Malformed input and unsafe ids: exit 0, no nudge, no marker, no row, and a diagnostic on stderr.
out=$(printf 'not json' | bash "$SENSOR" 2>"$ERR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "malformed stdin -- silent, exit 0"; else bad "malformed stdin: rc=$rc out='$out'"; fi
before=$(find "$TMPDIR" | wc -l | tr -d ' ')
out=$(run WebSearch "../evil"); rc=$?
after=$(find "$TMPDIR" | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$before" = "$after" ] && [ "$(rows)" = "$r0" ] && grep -q 'session_id is not a safe file name' "$ERR"; then
  ok "unsafe session_id -- no nudge, no marker, no row, diagnostic on stderr"
else
  bad "unsafe session id: rc=$rc out='$out' files $before->$after rows=$(rows) err=$(cat "$ERR")"
fi
out=$(run WebSearch s7 "../x"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows)" = "$r0" ] && grep -q 'agent_id is not a safe file name' "$ERR"; then
  ok "unsafe agent_id -- no nudge, no row, diagnostic on stderr"
else
  bad "unsafe agent id: rc=$rc out='$out' rows=$(rows) err=$(cat "$ERR")"
fi

# 8. Unwritable log: still exits 0 and still nudges, with a diagnostic.
out=$(MH_QMD_FIRST_LOG="/dev/null/x/log.jsonl" run WebSearch s6); rc=$?
if [ "$rc" -eq 0 ] && nudged "$out" && grep -q 'cannot write' "$ERR"; then ok "unwritable log -- fails open, still nudges, says why"; else bad "unwritable log: rc=$rc out='$out' err=$(cat "$ERR")"; fi

# 9. The Firecrawl connector's search counts as a web search.
out=$(run mcp__claude_ai_Firecrawl__firecrawl_search s8)
if nudged "$out"; then ok "Firecrawl search first -- nudged"; else bad "Firecrawl search should nudge: '$out'"; fi

# 10. A subagent's search is its own thread: nudged, and it does not use up the main thread's nudge.
out=$(run WebSearch s9 ag1)
if nudged "$out"; then ok "subagent first search -- nudged"; else bad "subagent should be nudged: '$out'"; fi
row=$(last_row)
if grep -q '"subagent": true' <<<"$row" && grep -q '"agent_id": "ag1"' <<<"$row"; then ok "log row names the subagent thread"; else bad "subagent row wrong: $row"; fi
out=$(run WebSearch s9 ag2)
if nudged "$out" && grep -q '"agent_id": "ag2"' <<<"$(last_row)"; then ok "a second subagent is its own thread and its own row"; else bad "second subagent: '$out' row=$(last_row)"; fi
out=$(run WebSearch s9)
if nudged "$out"; then ok "main thread still nudged after its subagents were"; else bad "main thread should keep its own nudge: '$out'"; fi

# 11. A subagent's qmd call counts for the whole session.
run mcp__plugin_qmd_qmd__query s10 ag3 >/dev/null
out=$(run WebSearch s10)
if [ -z "$out" ]; then ok "subagent qmd call before the main thread's search -- no nudge"; else bad "subagent qmd should count: '$out'"; fi

# 12. python3 missing: the shell wrapper allows and says so.
mkdir -p "$WORK/nopy"
ln -sf "$(command -v bash)" "$WORK/nopy/bash"
# The sensor never reads stdin here; a pipe would give the payload writer SIGPIPE under pipefail.
out=$(env PATH="$WORK/nopy" bash "$SENSOR" <<<"$(payload WebSearch s11)" 2>"$ERR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q 'python3 not found' "$ERR"; then ok "no python3 -- allowed with a diagnostic"; else bad "no python3: rc=$rc out='$out' err=$(cat "$ERR")"; fi

# 13. Shared hook_payload lib cannot load: silent, exit 0, diagnostic. Copy the sensor where scripts/_lib is absent.
mkdir -p "$WORK/copy/hooks/sensors"
cp "$ROOT/hooks/sensors/qmd-first-nudge.sh" "$ROOT/hooks/sensors/qmd-first-nudge.py" "$WORK/copy/hooks/sensors/"
out=$(payload WebSearch s12 | PATH="$WORK/bin:$PATH" bash "$WORK/copy/hooks/sensors/qmd-first-nudge.sh" 2>"$ERR"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q 'cannot load scripts/_lib/hook_payload.py' "$ERR"; then ok "hook_payload lib missing -- no nudge, diagnostic"; else bad "lib missing: rc=$rc out='$out' err=$(cat "$ERR")"; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
