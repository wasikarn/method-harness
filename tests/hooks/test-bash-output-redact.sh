#!/usr/bin/env bash
# Behavioral tests for hooks/sensors/bash-output-redact.sh (PostToolUse, Bash and MCP).
# Run standalone: bash tests/hooks/test-bash-output-redact.sh
#
# No literal token-shaped secret string appears in this file: every test token's
# random portion is generated at runtime, so the file never holds a
# live-credential-shaped substring (same rule as test-secret-scan.sh). The one
# exception is AWS's own published placeholder example.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
HOOK="$ROOT/hooks/sensors/bash-output-redact.sh"

pass=0
_r=0
fail=0

rnd() { # rnd <len> <charset> <seed>
  python3 -c 'import random,sys; r=random.Random(int(sys.argv[3])); print("".join(r.choice(sys.argv[2]) for _ in range(int(sys.argv[1]))))' "$1" "$2" "$3"
}
ALNUM="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
UPPER36="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

payload() { # payload <tool> <stdout> <stderr>
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":sys.argv[1],"tool_input":{"command":"x"},"tool_response":{"stdout":sys.argv[2],"stderr":sys.argv[3],"interrupted":False,"isImage":False,"noOutputExpected":False}}))' "$1" "$2" "$3"
}

# field <json> <dotted path> -- prints the value, empty when absent
field() {
  python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1])
    for k in sys.argv[2].split("."): d=d[k]
    print(d)
except Exception:
    pass' "$1" "$2"
}

GH="ghp_$(rnd 36 "$ALNUM" 1)"
AWS="AKIA$(rnd 16 "$UPPER36" 2)"
NPM="npm_$(rnd 36 "$ALNUM" 3)"
PEM_BODY="$(rnd 64 "$ALNUM" 4)"

echo "bash-output-redact"

# 1. token in stdout is replaced, shape preserved
out="$(payload Bash "token is $GH ok" "" | bash "$HOOK")"; rc=$?
[ "$rc" -eq 0 ] || _r=1; check "exit 0 on a hit" "$_r"; _r=0
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
[[ "$res" == *"[REDACTED:GitHub token]"* && "$res" != *"$GH"* ]] || _r=1; check "stdout token replaced by a labelled marker" "$_r"; _r=0
[ "$(field "$out" hookSpecificOutput.hookEventName)" = "PostToolUse" ] || _r=1; check "hookEventName is PostToolUse" "$_r"; _r=0
[ "$(field "$out" hookSpecificOutput.updatedToolOutput.interrupted)" = "False" ] || _r=1; check "other tool_response keys are carried over" "$_r"; _r=0

# 2. token in stderr
out="$(payload Bash "fine" "boom $AWS" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stderr)"
[[ "$res" == *"[REDACTED:AWS access/session key]"* && "$res" != *"$AWS"* ]] || _r=1; check "stderr token replaced" "$_r"; _r=0
[ "$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)" = "fine" ] || _r=1; check "untouched stream is byte-identical" "$_r"; _r=0

# 3. two tokens, one stream
out="$(payload Bash "$GH and $NPM" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
[[ "$res" != *"$GH"* && "$res" != *"$NPM"* ]] || _r=1; check "every match in a stream is replaced" "$_r"; _r=0

# 4. PEM block
pem="$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----' "$PEM_BODY")"
out="$(payload Bash "$pem" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
[[ "$res" == *"[REDACTED:Private key]"* && "$res" != *"$PEM_BODY"* ]] || _r=1; check "private key body replaced" "$_r"; _r=0

# 5. silent cases print nothing and exit 0
for case_desc in "clean output|Bash|hello world|" \
                 "AWS published placeholder|Bash|AKIAIOSFODNN7EXAMPLE|" \
                 "non-Bash tool|Read|$GH|"; do
  IFS='|' read -r desc tool so se <<<"$case_desc"
  out="$(payload "$tool" "$so" "$se" | bash "$HOOK")"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || _r=1; check "silent: $desc" "$_r"; _r=0
done

# 6. fail open on bad input
out="$(printf 'not json{' | bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || _r=1; check "invalid JSON: exit 0, no output" "$_r"; _r=0
out="$(printf '{"tool_name":"Bash","tool_response":"a string %s"}' "$GH" | bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || _r=1; check "non-object tool_response: exit 0, no output" "$_r"; _r=0
out="$(printf '{"tool_name":"Bash","tool_response":{"stdout":123,"stderr":null}}' | bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || _r=1; check "non-string streams: exit 0, no output" "$_r"; _r=0

# 6b. fail-open diagnostics are asserted, not discarded
err="$(printf 'not json{' | bash "$HOOK" 2>&1 >/dev/null)"
[[ "$err" == *"internal error"* ]] || _r=1; check "invalid JSON prints an internal-error diagnostic" "$_r"; _r=0
err="$(printf '[]' | bash "$HOOK" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$err" ]; } || _r=1; check "top-level non-object payload: silent, no false diagnostic" "$_r"; _r=0
tmp="$(mktemp -d)"; cp "$HOOK" "$tmp/bash-output-redact.sh"
payload Bash "$GH" "" >"$tmp/in.json"
err="$(bash "$tmp/bash-output-redact.sh" <"$tmp/in.json" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$err" == *"missing or unreadable"* && "$err" != *"$GH"* ]]; } || _r=1; check "missing sibling script: exit 0 with a diagnostic" "$_r"; _r=0
tmp_delete "$tmp"

# 6c. multi-line private key: every body line goes, up to and including the END line
body="$(for i in 1 2 3 4 5; do rnd 64 "$ALNUM" "1$i"; done)"
pem5="$(printf -- 'before\n-----BEGIN RSA PRIVATE KEY-----\n%s\n-----END RSA PRIVATE KEY-----\nafter' "$body")"
out="$(payload Bash "$pem5" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
line1="$(sed -n 1p <<<"$body")"; line5="$(sed -n 5p <<<"$body")"
{ [[ "$res" == *"[REDACTED:Private key]"* && "$res" != *"$line1"* && "$res" != *"$line5"* && "$res" == "before"* && "$res" == *"after" ]]; } || _r=1; check "5-line private key fully replaced, surrounding text kept" "$_r"; _r=0
trunc="$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n%s' "$line1" "$line5")"
out="$(payload Bash "$trunc" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
{ [[ "$res" == *"[REDACTED:Private key]"* && "$res" != *"$line1"* && "$res" != *"$line5"* ]]; } || _r=1; check "private key with no END line is replaced to end of stream" "$_r"; _r=0

# 6d. a token glued to a word character still goes (JSON-escaped newline, KEY_ prefix)
out="$(payload Bash "{\"msg\":\"a\\n$GH\"}" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
{ [[ "$res" == *"[REDACTED:GitHub token]"* && "$res" != *"$GH"* ]]; } || _r=1; check "token after a literal backslash-n is replaced" "$_r"; _r=0
out="$(payload Bash "KEY_$GH" "" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedToolOutput.stdout)"
{ [[ "$res" == *"[REDACTED:GitHub token]"* && "$res" != *"$GH"* ]]; } || _r=1; check "token after a name ending in underscore is replaced" "$_r"; _r=0

# 6e. MCP tool output: tool_response is a list of content blocks; text blocks are rewritten
# via updatedMCPToolOutput (probed 2026-10-22, GH #534), other blocks pass through
mcp_payload() { # mcp_payload <tool> <text>
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":sys.argv[1],"tool_input":{},"tool_response":[{"type":"text","text":sys.argv[2]},{"type":"image","data":"AAAA"}]}))' "$1" "$2"
}
out="$(mcp_payload mcp__srv__get "note $GH end" | bash "$HOOK")"; rc=$?
[ "$rc" -eq 0 ] || _r=1; check "MCP hit: exit 0" "$_r"; _r=0
res="$(field "$out" hookSpecificOutput.updatedMCPToolOutput)"
[[ "$res" == *"[REDACTED:GitHub token]"* && "$res" != *"$GH"* && "$res" == *"AAAA"* ]] || _r=1; check "MCP text block redacted, image block kept" "$_r"; _r=0
{ [ -z "$(field "$out" hookSpecificOutput.updatedToolOutput)" ] && [ -n "$res" ]; } || _r=1; check "MCP result uses updatedMCPToolOutput only" "$_r"; _r=0
out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__srv__get","tool_response":[{"type":"resource","resource":{"uri":"file:///x","text":"embedded "+sys.argv[1]}}]}))' "$GH" | bash "$HOOK")"
res="$(field "$out" hookSpecificOutput.updatedMCPToolOutput)"
{ [[ "$res" == *"[REDACTED:GitHub token]"* && "$res" != *"$GH"* && "$res" == *"file:///x"* ]]; } || _r=1; check "MCP embedded resource text redacted, uri kept" "$_r"; _r=0
out="$(mcp_payload mcp__srv__get "nothing here" | bash "$HOOK")"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } || _r=1; check "silent: clean MCP output" "$_r"; _r=0
out="$(printf '{"tool_name":"mcp__srv__get","tool_response":"a string %s"}' "$GH" | bash "$HOOK" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } || _r=1; check "silent: MCP tool_response that is not a block list" "$_r"; _r=0

# 7. large clean output stays fast and silent
big="$(python3 -c 'print("line of ordinary text\n" * 20000)')"
start=$SECONDS
out="$(payload Bash "$big" "" | bash "$HOOK")"
[ -z "$out" ] && [ $((SECONDS - start)) -lt 5 ] || _r=1; check "400 KB clean output: silent, under 5 s" "$_r"; _r=0

echo
echo "bash-output-redact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
