#!/usr/bin/env bash
# gate:agent:subagent-verdict-check -- Tier 1 of the "auto-apply the attacker
# pattern via hooks?" design note (docs/research/
# nine-agent-gate-architecture-security-audit-2026-09-20.md). Runs every case
# through subagent-verdict-gate.sh (not the .py directly), matching this
# repo's convention that the shell wrapper is part of the contract under test.
# Run standalone: bash tests/hooks/test-subagent-verdict-gate.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/hooks/gates/subagent-verdict-gate.sh"

# The gate journals every block it makes; keep those rows out of the real journal, where
# "test-session" rows were read as live gate events by gate-report.
JOURNAL="$(mktemp)" || { echo "mktemp failed: no scratch journal, refusing to run against the real one" >&2; exit 1; }
export MH_GATE_JOURNAL_PATH="$JOURNAL"
trap 'rm -f "$JOURNAL"' EXIT

pass=0
fail=0

check() {
  local desc="$1" ok="$2"
  if [ "$ok" -eq 0 ]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

# payload <msg-json-string> [stop_hook_active]
payload() {
  python3 -c "
import json, sys
msg = sys.argv[1]
d = {'hook_event_name': 'SubagentStop', 'agent_type': 'general-purpose',
     'session_id': 'test-session', 'last_assistant_message': msg}
if len(sys.argv) > 2 and sys.argv[2] == 'active':
    d['stop_hook_active'] = True
print(json.dumps(d))
" "$1" "${2:-}"
}

# run <msg-json-string> [stop_hook_active] -> sets $OUT, $CODE
run() {
  OUT="$(payload "$1" "${2:-}" | bash "$SH" 2>/dev/null)"
  CODE=$?
}

echo "=== subagent-verdict-gate.sh: SubagentStop verdict-shape tests ==="
echo ""

# --- vacuous pass: blocks ---
run '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}'
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "vacuous pass (no findings, no checked[]) blocks" "$ok"
[ "$CODE" -eq 0 ]; check "block is still exit 0 (JSON on stdout, not a hook crash)" "$?"

# --- real pass with checked[]: allows ---
run '{"pass": true, "findings": [], "checked": [{"claim": "x", "evidence": "y"}], "scope_ok": true, "unexpected_files": []}'
[ -z "$OUT" ]; check "real pass with checked[] evidence: silent allow" "$?"

# --- self-contradictory: pass true, scope_ok false ---
run '{"pass": true, "findings": [], "checked": [{"claim": "x", "evidence": "y"}], "scope_ok": false, "unexpected_files": []}'
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "pass:true + scope_ok:false blocks" "$ok"

# --- self-contradictory: pass true, unexpected_files non-empty ---
run '{"pass": true, "findings": [], "checked": [{"claim": "x", "evidence": "y"}], "scope_ok": true, "unexpected_files": ["extra.py"]}'
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "pass:true + non-empty unexpected_files blocks" "$ok"

# --- oversized message: skipped entirely, even a vacuous pass allows ---
run_oversized() {
  local f
  f="$(mktemp)"
  python3 -c "
import json
pad = 'x' * 200_001
msg = '{\"pass\": true, \"findings\": [], \"scope_ok\": true, \"unexpected_files\": []} ' + pad
d = {'hook_event_name': 'SubagentStop', 'agent_type': 'general-purpose',
     'session_id': 'test-session', 'last_assistant_message': msg}
print(json.dumps(d))
" > "$f"
  OUT="$(/bin/bash "$SH" < "$f" 2>/dev/null)"
  CODE=$?
  rm -f "$f"
}
run_oversized
[ -z "$OUT" ]; check "message over 200k chars: skipped, silent allow even on vacuous pass" "$?"

# --- pass:false with real findings: allows ---
run '{"pass": false, "findings": [{"summary": "s", "evidence": "e"}], "checked": [{"claim": "x", "evidence": "y"}], "scope_ok": true, "unexpected_files": []}'
[ -z "$OUT" ]; check "pass:false with real findings: silent allow" "$?"

# --- NEEDS-DECISION always allows, even with a decoy JSON blob ---
run 'NEEDS-DECISION which schema should I use? (example: {"pass": true})'
[ -z "$OUT" ]; check "NEEDS-DECISION text: silent allow" "$?"

# --- ambiguous: two distinct pass-bearing objects ---
run 'Draft: {"pass": true, "findings": []} then final: {"pass": false, "findings": [{"summary":"s","evidence":"e"}]}'
[ -z "$OUT" ]; check "two distinct pass objects: allow (ambiguous, noted on stderr only)" "$?"

# --- ordinary prose, no verdict shape: allows ---
run 'I explored the codebase and found three files matching the pattern.'
[ -z "$OUT" ]; check "ordinary non-verdict prose: silent allow" "$?"

# --- stop_hook_active: already re-prompted once, never block again ---
run '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' active
[ -z "$OUT" ]; check "stop_hook_active:true: never blocks a second time" "$?"

# --- 2026-09-21 deep-audit: _find_json_dicts was O(n x braces): 30,000
# leading "{" before a vacuous verdict took ~15s through the .sh wrapper,
# past the 8s SubagentStop timeout, so the block was dropped. `timeout 5`
# wraps the run: a regression to the unbounded scan fails by rc 124. ---
run_braces() { # run_braces <n-leading-braces> -> $OUT, $CODE
  local f
  f="$(mktemp)"
  python3 -c "
import json, sys
n = int(sys.argv[1])
msg = '{' * n + ' {\"pass\": true, \"findings\": [], \"scope_ok\": true, \"unexpected_files\": []}'
d = {'hook_event_name': 'SubagentStop', 'agent_type': 'general-purpose',
     'session_id': 'test-session', 'last_assistant_message': msg}
print(json.dumps(d))
" "$1" > "$f"
  OUT="$(timeout 5 /bin/bash "$SH" < "$f" 2>/dev/null)"
  CODE=$?
  rm -f "$f"
}
run_braces 30000
[ "$CODE" -ne 124 ]; check "30k leading braces: finishes under timeout 5 (rc $CODE, not 124), no silent timeout-drop" "$?"
run_braces 10000
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "10k leading braces before a vacuous verdict: still blocks" "$ok"

# --- validator catch, same day: the first budget charged every popped span's
# full length, so 1500 NESTED braces ({...{}...}) before a vacuous verdict
# cost N(N+1) work and took the fail-open ALLOW path -- a cheaper bypass
# than the one just closed. Work is charged per character walked only. ---
run_nested_braces() { # run_nested_braces <n> -> $OUT, $CODE
  local f
  f="$(mktemp)"
  python3 -c "
import json, sys
n = int(sys.argv[1])
msg = '{' * n + '}' * n + ' {\"pass\": true, \"findings\": [], \"scope_ok\": true, \"unexpected_files\": []}'
d = {'hook_event_name': 'SubagentStop', 'agent_type': 'general-purpose',
     'session_id': 'test-session', 'last_assistant_message': msg}
print(json.dumps(d))
" "$1" > "$f"
  OUT="$(timeout 5 /bin/bash "$SH" < "$f" 2>/dev/null)"
  CODE=$?
  rm -f "$f"
}
run_nested_braces 1500
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "1500 nested braces before a vacuous verdict: still blocks (rc $CODE), no budget fail-open" "$ok"

# --- 2026-09-21 deep-audit: two IDENTICAL pass-bearing objects were counted
# as "2 distinct, ambiguous" and allowed; dedupe by canonical JSON first. ---
run '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []} ... as I said: {"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}'
grep -q '"decision": *"block"' <<<"$OUT" && ok=0 || ok=1
check "the same vacuous verdict printed twice: still blocks (identical objects are one verdict, not two)" "$ok"
run '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []} vs {"pass": true, "findings": [], "checked": [{"claim":"x","evidence":"y"}], "scope_ok": true, "unexpected_files": []}'
[ -z "$OUT" ]; check "two DISTINCT pass:true objects: still allow (ambiguous)" "$?"


# --- GH #160: on CC >= 2.1.271 in auto mode the report is delivered via the
# SubagentHandback tool, and last_assistant_message holds only the closing
# text. The same check runs as a PreToolUse hook on tool_input.message
# (code.claude.com/docs/en/hooks.md, SubagentStop section), denying with the
# hookSpecificOutput shape. ---
# handback_payload <message> [event] [tool_name]
handback_payload() {
  python3 -c "
import json, sys
msg, event, tool = sys.argv[1], sys.argv[2], sys.argv[3]
d = {'tool_name': tool, 'tool_input': {'message': msg}, 'agent_id': 'agent-1',
     'agent_type': 'general-purpose', 'session_id': 'test-session'}
if event != '-':
    d['hook_event_name'] = event
print(json.dumps(d))
" "$1" "${2:-PreToolUse}" "${3:-SubagentHandback}"
}
run_handback() { # run_handback <message> [event] [tool_name] -> $OUT, $CODE
  OUT="$(handback_payload "$1" "${2:-PreToolUse}" "${3:-SubagentHandback}" | bash "$SH" 2>/dev/null)"
  CODE=$?
}

run_handback '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}'
grep -q '"permissionDecision": *"deny"' <<<"$OUT" && grep -q '"hookEventName": *"PreToolUse"' <<<"$OUT" && ok=0 || ok=1
check "PreToolUse SubagentHandback: vacuous pass in tool_input.message denies (hookSpecificOutput deny JSON)" "$ok"
[ "$CODE" -eq 0 ]; check "PreToolUse deny is exit 0 (JSON on stdout, not an exit-2 crash)" "$?"

run_handback '{"pass": true, "findings": [], "checked": [{"claim": "x", "evidence": "y"}], "scope_ok": true, "unexpected_files": []}'
[ -z "$OUT" ] && [ "$CODE" -eq 0 ]; check "PreToolUse SubagentHandback: real pass with checked[] evidence: silent allow" "$?"

run_handback 'Handing back: I explored the codebase and found three files matching the pattern.'
[ -z "$OUT" ] && [ "$CODE" -eq 0 ]; check "PreToolUse SubagentHandback: non-verdict report text: silent allow" "$?"

run_handback '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' -
[ -z "$OUT" ] && [ "$CODE" -eq 0 ]; check "PreToolUse payload with hook_event_name missing: silent allow (fail-open)" "$?"

run_handback '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' PreToolUse Agent
[ -z "$OUT" ] && [ "$CODE" -eq 0 ]; check "PreToolUse on a different tool_name: silent allow" "$?"

run_handback_malformed() { # truncated JSON on stdin -> $OUT, $CODE
  OUT="$(printf '{"hook_event_name": "PreToolUse", "tool_name": "SubagentHandback", "tool_input": {"message": ' | bash "$SH" 2>/dev/null)"
  CODE=$?
}
run_handback_malformed
[ -z "$OUT" ] && [ "$CODE" -eq 0 ]; check "PreToolUse malformed stdin (truncated JSON): exit 0, no deny JSON (fail-open)" "$?"

# --- GH #156 drift guard: every gate raises the int-string digit limit
# before json.load(); this one was missing it. ---
command grep -q 'sys.set_int_max_str_digits(0)' "$ROOT/hooks/gates/subagent-verdict-gate.py"; check "GH #156 guard present (set_int_max_str_digits) in subagent-verdict-gate.py" "$?"

# --- fail-open on missing python3 ---
run_no_python3() {
  # Write the payload to a file first, not a pipe -- with `set -o pipefail`,
  # the shell script exiting before python3 finishes writing raises a
  # BrokenPipeError in the payload generator, which then (wrongly) becomes
  # this test's observed exit code instead of subagent-verdict-gate.sh's own.
  local f
  f="$(mktemp)"
  payload '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' > "$f"
  OUT="$(PATH="/nonexistent" /bin/bash "$SH" < "$f" 2>/dev/null)"
  CODE=$?
  rm -f "$f"
}
run_no_python3
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]; check "missing python3: exit 0, no block JSON (fail-open)" "$?"

# --- fail-open when the sibling .py is missing (would otherwise let
# python3's own "no such file" exit code, commonly 2, be misread by Claude
# Code as an explicit SubagentStop block) ---
run_missing_sibling() {
  local f tmp_sh
  f="$(mktemp)"
  payload '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' > "$f"
  tmp_sh="$(mktemp)"
  sed "s#subagent-verdict-gate.py#does-not-exist.py#" "$SH" > "$tmp_sh"
  OUT="$(/bin/bash "$tmp_sh" < "$f" 2>/dev/null)"
  CODE=$?
  rm -f "$f" "$tmp_sh"
}
run_missing_sibling
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]; check "missing sibling .py: exit 0, no block JSON (fail-open)" "$?"

[ -s "$JOURNAL" ]; check "block rows landed in the override journal (the export is still wired)" "$?"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
