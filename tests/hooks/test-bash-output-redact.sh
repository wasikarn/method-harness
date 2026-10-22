#!/usr/bin/env bash
# Behavioral tests for hooks/sensors/bash-output-redact.sh (PostToolUse, Bash).
# Run standalone: bash tests/hooks/test-bash-output-redact.sh
#
# No literal token-shaped secret string appears in this file: every test token's
# random portion is generated at runtime, so the file never holds a
# live-credential-shaped substring (same rule as test-secret-scan.sh). The one
# exception is AWS's own published placeholder example.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# 7. large clean output stays fast and silent
big="$(python3 -c 'print("line of ordinary text\n" * 20000)')"
start=$SECONDS
out="$(payload Bash "$big" "" | bash "$HOOK")"
[ -z "$out" ] && [ $((SECONDS - start)) -lt 5 ] || _r=1; check "400 KB clean output: silent, under 5 s" "$_r"; _r=0

echo
echo "bash-output-redact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
