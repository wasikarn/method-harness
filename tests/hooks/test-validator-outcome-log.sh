#!/usr/bin/env bash
# Validator-outcome log (GH #994, C1 of the mh quality plan): subagent-verdict-gate.sh
# appends one counts-and-booleans row per Rule 13 verdict it sees, on the allow path as
# well as the block path, so the first-pass rate and the rounds needed become measurable.
# The row must never change the gate's verdict or exit code, must never hold prompt text,
# a path or a finding's text, and every failure to write must be swallowed.
# Run standalone: bash tests/hooks/test-validator-outcome-log.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/hooks/gates/subagent-verdict-gate.sh"
. "$ROOT/scripts/_lib/tmp-delete.sh"

TMP="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
trap 'tmp_delete "$TMP"' EXIT
export MH_GATE_JOURNAL_PATH="$TMP/gate-decisions.jsonl"
OUTCOMES="$TMP/validator-outcomes.jsonl"
export MH_VALIDATOR_OUTCOMES_PATH="$OUTCOMES"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

# send <event: stop|handback> <message> [active]  -> sets $OUT, $CODE
send() {
  OUT="$(python3 -c "
import json, sys
ev, msg, active = sys.argv[1], sys.argv[2], len(sys.argv) > 3
if ev == 'stop':
    d = {'hook_event_name': 'SubagentStop', 'agent_type': 'general-purpose', 'session_id': 's1',
         'last_assistant_message': msg}
    if active:
        d['stop_hook_active'] = True
else:
    d = {'hook_event_name': 'PreToolUse', 'tool_name': 'SubagentHandback', 'agent_type': 'general-purpose',
         'session_id': 's1', 'tool_input': {'message': msg}}
print(json.dumps(d))
" "$@" | bash "$SH" 2>/dev/null)"
  CODE=$?
}

# rows -> number of rows; row N -> value of a field (python json, N is 1-based)
rows() { [ -f "$OUTCOMES" ] && wc -l < "$OUTCOMES" | tr -d ' ' || echo 0; }
field() { python3 -c "
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2]) - 1]
print(json.dumps(r.get(sys.argv[3])))
" "$OUTCOMES" "$1" "$2"; }
reset() { : > "$OUTCOMES"; }
# status-returning helpers: shellcheck (SC2319) rejects reading $? right after a test that holds a $(...)
rows_is() { [ "$(rows)" = "$1" ]; }
field_is() { [ "$(field "$1" "$2")" = "$3" ]; }
field_ge() { [ "$(field "$1" "$2")" -ge "$3" ]; }

CLEAN='{"pass": true, "findings": [], "checked": ["read a.py:3"], "scope_ok": true, "unexpected_files": []}'
VACUOUS='{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}'

echo "=== validator outcome log ==="

reset
send stop "$CLEAN"
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]; check "clean pass is still allowed (exit 0, no block JSON)" "$?"
rows_is 1; check "clean pass on the allow path writes one row" "$?"
field_is 1 event '"stop"' && field_is 1 pass 'true' && field_is 1 checked '1' \
  && field_is 1 findings '0' && field_is 1 denied 'false' && field_is 1 flaws '0'
check "row holds event, pass, counts, denied=false, flaws=0" "$?"
field_is 1 agent_type '"general-purpose"' && field_is 1 session_id '"s1"'; check "row holds agent_type and session_id" "$?"

reset
send stop "$VACUOUS"
grep -q '"decision": *"block"' <<<"$OUT"; check "vacuous pass still blocks" "$?"
rows_is 1 && field_is 1 denied 'true' && field_ge 1 flaws 1; check "blocked verdict writes a row with denied=true and flaws>=1" "$?"

reset
send handback "$VACUOUS"
grep -q '"permissionDecision": *"deny"' <<<"$OUT"; check "handback path: vacuous pass still denied" "$?"
rows_is 1 && field_is 1 event '"handback"' && field_is 1 denied 'true'; check "handback path writes a row with event=handback, denied=true" "$?"

reset
send handback "$CLEAN"
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rows_is 1 && field_is 1 event '"handback"' && field_is 1 denied 'false'
check "handback path: clean pass allowed, one row, denied=false" "$?"

# The corrected verdict arrives with stop_hook_active set: the gate never blocks twice, but the
# round must still be recorded (this is the second round of a failed first-pass).
reset
send stop "$VACUOUS" active
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]; check "stop_hook_active: still never blocks a second time" "$?"
rows_is 1 && field_is 1 denied 'false' && field_ge 1 flaws 1; check "stop_hook_active: round recorded with denied=false, flaws>=1" "$?"

reset
send stop "$CLEAN" active
rows_is 1 && field_is 1 flaws '0'; check "stop_hook_active: corrected clean verdict recorded" "$?"

# --- no row when there is no single, checkable verdict ---
reset
send stop "I edited three files and everything passes."
rows_is 0; check "prose with no verdict object writes no row" "$?"
send stop '{"pass": false, "findings": [], "checked": ["read a.py:3"], "scope_ok": true, "unexpected_files": []} NEEDS-DECISION which db?'
rows_is 0; check "NEEDS-DECISION writes no row" "$?"
send stop "$CLEAN and also $VACUOUS"
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rows_is 0; check "two distinct verdicts (ambiguous): allowed, no row" "$?"
send stop ""
rows_is 0; check "empty message writes no row" "$?"

# --- privacy: counts and booleans only ---
reset
send stop '{"pass": false, "findings": [{"summary": "SECRET-MARKER-123 in /srv/someone/private.py"}], "checked": ["ran cmd SECRET-MARKER-456"], "scope_ok": false, "unexpected_files": ["/srv/someone/x.py"]}'
rows_is 1; check "failing verdict writes a row" "$?"
! grep -q -E 'SECRET-MARKER|/srv/|private\.py' "$OUTCOMES"; check "row holds no finding text, command text or path" "$?"
python3 -c "
import json, sys
allowed = {'ts','event','agent_type','session_id','mh_version','pass','findings','checked','scope_ok','unexpected','flaws','denied'}
bad = [k for l in open(sys.argv[1]) for k in json.loads(l) if k not in allowed]
sys.exit(1 if bad else 0)
" "$OUTCOMES"; check "row keys are exactly the whitelist" "$?"
field_is 1 findings '1' && field_is 1 unexpected '1' && field_is 1 pass 'false' && field_is 1 scope_ok 'false'
check "counts and flags are taken from the verdict" "$?"

# --- fail silent: the row can never change the verdict ---
BAD_DIR="$TMP/is-a-dir"; mkdir -p "$BAD_DIR"
MH_VALIDATOR_OUTCOMES_PATH="$BAD_DIR" send stop "$VACUOUS"
grep -q '"decision": *"block"' <<<"$OUT" && [ "$CODE" -eq 0 ]; check "unwritable outcomes path: vacuous pass still blocks, exit 0" "$?"
MH_VALIDATOR_OUTCOMES_PATH="$BAD_DIR" send stop "$CLEAN"
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]; check "unwritable outcomes path: clean pass still allowed, exit 0" "$?"

REAL="$TMP/real.jsonl"; : > "$REAL"; ln -s "$REAL" "$TMP/link.jsonl"
MH_VALIDATOR_OUTCOMES_PATH="$TMP/link.jsonl" send stop "$CLEAN"
[ "$CODE" -eq 0 ] && [ ! -s "$REAL" ]; check "outcomes path that is a symlink is refused (nothing written through it)" "$?"

# --- rounds: a denied verdict followed by its corrected one stays two ordered rows ---
reset
send stop "$VACUOUS"
send stop "$CLEAN" active
rows_is 2 && field_is 1 denied 'true' && field_ge 1 flaws 1 && field_is 2 denied 'false' && field_is 2 flaws '0'; check "SubagentStop: deny then corrected verdict = two rows (denied=true then denied=false, flaws=0)" "$?"
reset
send handback "$VACUOUS"
send handback "$CLEAN"
rows_is 2 && field_is 1 event '"handback"' && field_is 1 denied 'true' && field_is 2 event '"handback"' && field_is 2 denied 'false'; check "SubagentHandback: deny then corrected verdict = two rows in order" "$?"

# --- double count: on CC >= 2.1.271 in auto mode the report goes through SubagentHandback and the
# SubagentStop message holds only the closing text, so one report is one row ---
reset
send handback "$CLEAN"
send stop "Done. The verdict was returned through SubagentHandback."
rows_is 1; check "handback verdict plus a closing-text-only stop: one row, no double count" "$?"
# If both messages do carry the verdict, two rows are written; the event field lets a reader drop one
# (rule in docs/reference/measurement-coverage-status.md: same session and agent_type, same counts, within a few seconds).
reset
send handback "$CLEAN"
send stop "$CLEAN"
rows_is 2 && field_is 1 event '"handback"' && field_is 2 event '"stop"'; check "both messages carry the verdict: two rows told apart by event" "$?"

# --- mh_version comes from the plugin manifest ---
PR="$TMP/plugin-root"; mkdir -p "$PR/.claude-plugin"; printf '{"version": "9.9.9"}\n' > "$PR/.claude-plugin/plugin.json"
reset
CLAUDE_PLUGIN_ROOT="$PR" send stop "$CLEAN"
field_is 1 mh_version '"9.9.9"'; check "mh_version is read from CLAUDE_PLUGIN_ROOT's plugin.json" "$?"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
