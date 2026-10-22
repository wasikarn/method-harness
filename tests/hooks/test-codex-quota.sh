#!/usr/bin/env bash
# Unit tests for hooks/sensors/codex-quota-{sensor,advisory}.{sh,py}.
# Advisory-only pair: sensor records a Codex CLI usage-limit/rate-limit
# failure (PostToolUseFailure/Bash), advisory warns on the next Codex Bash
# call while the record is fresh (PreToolUse/Bash). Neither ever blocks.
# Run standalone: bash tests/hooks/test-codex-quota.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SENSOR="$ROOT/hooks/sensors/codex-quota-sensor.sh"
ADVISORY="$ROOT/hooks/sensors/codex-quota-advisory.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

failure_payload() {
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "tool_use_id": "toolu_test", "error": sys.argv[2]}))' "$1" "$2"
}

pretooluse_payload() {
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$1"
}

STATE_DIR=$(mktemp -d)
trap '[ -n "$STATE_DIR" ] && rm -rf "$STATE_DIR" 2>/dev/null || true' EXIT
STATE="$STATE_DIR/state.json"

# --- a non-Codex command failing with quota-shaped text is ignored ---
out=$(failure_payload "npm install" "quota exceeded" | bash "$SENSOR" "$STATE")
if [ -z "$out" ] && [ ! -f "$STATE" ]; then
  ok "non-codex command failure never records, regardless of error text"
else
  bad "expected no output and no state file for a non-codex command, got out='$out' state_exists=$([ -f "$STATE" ] && echo yes || echo no)"
fi

# --- a codex command failing with a non-quota error is ignored ---
out=$(failure_payload "codex exec 'do the thing'" "some unrelated network error" | bash "$SENSOR" "$STATE")
if [ -z "$out" ] && [ ! -f "$STATE" ]; then
  ok "codex command failing on a non-quota error never records"
else
  bad "expected no state file for a non-quota codex failure, got out='$out'"
fi

# --- a codex command failing with a quota-shaped error records state, never blocks ---
out=$(failure_payload "codex exec 'do the thing'" "Usage limit reached, try again at Sep 26th" | bash "$SENSOR" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -f "$STATE" ]; then
  ok "codex + quota-shaped failure records state and exits 0 with no output (sensor never itself warns)"
else
  bad "expected exit 0, no output, and a written state file, got rc=$rc out='$out' state_exists=$([ -f "$STATE" ] && echo yes || echo no)"
fi

# --- advisory warns on the next codex Bash call while the record is fresh ---
out=$(pretooluse_payload "codex exec 'retry'" | bash "$ADVISORY" "$STATE")
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | /usr/bin/grep -q 'mh-codex-quota-advisory'; then
  ok "advisory warns on a fresh record, exit 0 (never blocks)"
else
  bad "expected an advisory nudge and exit 0, got rc=$rc out='$out'"
fi
if echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["hookSpecificOutput"]["hookEventName"] == "PreToolUse" and "additionalContext" in d["hookSpecificOutput"] else 1)'; then
  ok "advisory payload is additionalContext-only, no permissionDecision (never denies)"
else
  bad "expected hookSpecificOutput.additionalContext with no permissionDecision, got: $out"
fi

# --- advisory stays silent for a non-codex command even with a fresh record ---
out=$(pretooluse_payload "npm test" | bash "$ADVISORY" "$STATE")
if [ -z "$out" ]; then
  ok "advisory ignores a non-codex command even while a record exists"
else
  bad "expected no output for a non-codex command, got out='$out'"
fi

# --- advisory self-clears a stale (past-TTL) record instead of warning forever ---
# TTL=-1 guarantees staleness regardless of clock timing (age is always >= 0 > -1).
payload=$(pretooluse_payload "codex exec 'again'")
out=$(echo "$payload" | MH_CODEX_QUOTA_TTL_SECONDS=-1 bash "$ADVISORY" "$STATE")
if [ -z "$out" ] && [ ! -f "$STATE" ]; then
  ok "advisory treats a record older than TTL as stale, removes it, and stays silent"
else
  bad "expected a negative TTL to make any existing record immediately stale, got out='$out' state_exists=$([ -f "$STATE" ] && echo yes || echo no)"
fi

# --- GH #333: the Codex plugin's own runner, codex-companion.mjs (false negative: the
# trailing token boundary rejected the "-companion" suffix, so the main dispatch path never
# recorded or warned). Command form is the one the plugin's docs use, unexpanded.
COMPANION='node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" task "review the diff"'

# Real logged-out failure text (captured from codex-companion.mjs task, codex-cli 0.160.0,
# empty CODEX_HOME): exit 1, this line on stdout. Not quota-shaped, so it must not record.
out=$(failure_payload "$COMPANION" "Exit code 1
unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses" | bash "$SENSOR" "$STATE")
if [ -z "$out" ] && [ ! -f "$STATE" ]; then
  ok "companion command failing logged-out (401) never records"
else
  bad "expected no state file for a logged-out companion failure, got out='$out'"
fi

# Quota text: the companion relays the app-server error message verbatim to stdout (and as
# "[codex] Codex error: <msg>" on stderr); "You've hit your usage limit." is that message's
# wording in the codex binary. Inferred, not reproduced: an exhausted account was not available.
out=$(failure_payload "$COMPANION" "Exit code 1
[codex] Codex error: You've hit your usage limit.
[codex] Turn failed.
You've hit your usage limit." | bash "$SENSOR" "$STATE")
if [ -z "$out" ] && [ -f "$STATE" ]; then
  ok "companion command + usage-limit failure records state"
else
  bad "expected a state file for a companion usage-limit failure, got out='$out' state_exists=$([ -f "$STATE" ] && echo yes || echo no)"
fi

out=$(pretooluse_payload "$COMPANION" | bash "$ADVISORY" "$STATE")
if echo "$out" | /usr/bin/grep -q 'mh-codex-quota-advisory'; then
  ok "advisory warns on the next companion command while the record is fresh"
else
  bad "expected an advisory for the next companion command, got out='$out'"
fi

# --- GH #326: the advisory skips python3 when no state file exists (the common path).
# A python3 stub on PATH touches a marker, so each row asserts whether python ran.
_PYREAL="$(command -v python3)"
mkdir -p "$STATE_DIR/stub"
printf '#!/bin/sh\n: >> "$PYSTUB_MARK"\nexec "%s" "$@"\n' "$_PYREAL" > "$STATE_DIR/stub/python3"
chmod +x "$STATE_DIR/stub/python3"
export PYSTUB_MARK="$STATE_DIR/python-ran"
adv() { # adv <payload> [args...] -> out, py (yes|no); env passes through from the caller
  local p="$1"; shift
  rm -f "$PYSTUB_MARK"
  out=$(printf '%s' "$p" | PATH="$STATE_DIR/stub:$PATH" bash "$ADVISORY" "$@" 2>&1)
  if [ -e "$PYSTUB_MARK" ]; then py=yes; else py=no; fi
}
fresh_state() { printf '{"recorded_at": %s, "message": "Usage limit reached"}' "$(date +%s)" > "$1"; }
CODEX_P=$(pretooluse_payload "codex exec 'go'")
FAKE_HOME="$STATE_DIR/home"; mkdir -p "$FAKE_HOME/.cache/mh"

rm -f "$STATE"
MH_CODEX_QUOTA_STATE_FILE="$STATE" adv "$CODEX_P"
if [ -z "$out" ] && [ "$py" = no ]; then ok "GH #326 no state file (env path): silent, python3 never starts"
else bad "expected silence and no python3 run, got out='$out' python=$py"; fi

HOME="$FAKE_HOME" MH_CODEX_QUOTA_STATE_FILE='' adv "$CODEX_P"
if [ -z "$out" ] && [ "$py" = no ]; then ok "GH #326 no state file (default HOME path): silent, python3 never starts"
else bad "expected silence and no python3 run at the default path, got out='$out' python=$py"; fi

fresh_state "$FAKE_HOME/.cache/mh/codex-quota-state.json"
HOME="$FAKE_HOME" MH_CODEX_QUOTA_STATE_FILE='' adv "$CODEX_P"
if [ "$py" = yes ] && echo "$out" | /usr/bin/grep -q 'mh-codex-quota-advisory'; then
  ok "GH #326 empty MH_CODEX_QUOTA_STATE_FILE falls back to the HOME default, as python does"
else bad "expected an advisory from the HOME default state file, got out='$out' python=$py"; fi

fresh_state "$STATE"
MH_CODEX_QUOTA_STATE_FILE="$STATE" adv "$CODEX_P" "$STATE_DIR/absent.json"
if [ -z "$out" ] && [ "$py" = no ]; then ok "GH #326 an argv state path wins over the env path (absent argv file: silent, no python3)"
else bad "expected the argv path to decide, got out='$out' python=$py"; fi

MH_CODEX_QUOTA_STATE_FILE="$STATE_DIR/absent.json" adv "$CODEX_P" "$STATE"
if [ "$py" = yes ] && echo "$out" | /usr/bin/grep -q 'mh-codex-quota-advisory'; then
  ok "GH #326 a present argv state file reaches python3 and warns"
else bad "expected python3 and an advisory from the argv state file, got out='$out' python=$py"; fi

out=$(pretooluse_payload "npm test" | env -u HOME -u MH_CODEX_QUOTA_STATE_FILE bash "$ADVISORY" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "GH #326 HOME unset: no unbound-variable error, exit 0 and silent"
else bad "expected exit 0 and no output with HOME unset, got rc=$rc out='$out'"; fi

# --- known reset time: the sensor parses "try again at ..." into reset_at; the advisory denies
# while that time is in the future (a doomed dispatch burns a round-trip, and five parallel
# lanes burned five), keeps the old advice when the time is unknown, and drops a reset record.
S2="$STATE_DIR/reset-state.json"
state_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], "MISSING"))' "$1" "$2"; }

rm -f "$S2"
failure_payload "codex exec 'x'" "You've hit your usage limit. Try again at Jan 2nd, 2099 3:05 PM." | bash "$SENSOR" "$S2"
want=$(python3 -c 'import datetime,time; print(int(time.mktime(datetime.datetime(2099,1,2,15,5).timetuple())))')
got=$(state_field "$S2" reset_at)
if [ "$got" = "$want" ]; then ok "sensor parses a dated 'try again at' into reset_at (local time)"
else bad "expected reset_at=$want for a dated reset, got '$got'"; fi

rm -f "$S2"
failure_payload "codex exec 'x'" "You've hit your usage limit. Try again at 9:47 PM." | bash "$SENSOR" "$S2"
got=$(state_field "$S2" reset_at)
now=$(date +%s)
if [ "$got" != MISSING ] && [ "$got" -gt "$((now - 5))" ] && [ "$got" -le "$((now + 86400 + 5))" ]; then
  ok "sensor reads a time-only reset as its next occurrence (within 24 h)"
else bad "expected reset_at in (now, now+24h] for a time-only reset, got '$got' (now=$now)"; fi

rm -f "$S2"
failure_payload "codex exec 'x'" "Usage limit reached, try again at Sep 26th" | bash "$SENSOR" "$S2"
got=$(state_field "$S2" reset_at)
if [ "$got" = MISSING ]; then ok "sensor leaves reset_at out when the message has no readable time"
else bad "expected no reset_at for an unreadable reset, got '$got'"; fi

future_state() { printf '{"recorded_at": %s, "reset_at": %s, "message": "Usage limit reached"}' "$(date +%s)" "$(( $(date +%s) + 7200 ))" > "$1"; }
future_state "$S2"
out=$(pretooluse_payload "codex exec 'go'" | bash "$ADVISORY" "$S2"); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | python3 -c '
import json, sys
h = json.load(sys.stdin)["hookSpecificOutput"]
r = h.get("permissionDecisionReason", "")
sys.exit(0 if h["hookEventName"] == "PreToolUse" and h.get("permissionDecision") == "deny" and "MH_CODEX_QUOTA_DENY" in r and "reset-state.json" in r else 1)'; then
  ok "advisory denies a codex command while a known reset time is in the future, and names the way out"
else bad "expected a deny naming MH_CODEX_QUOTA_DENY and the state file, got rc=$rc out='$out'"; fi

out=$(pretooluse_payload "codex exec 'go'" | MH_CODEX_QUOTA_DENY=0 bash "$ADVISORY" "$S2")
if echo "$out" | python3 -c '
import json, sys
h = json.load(sys.stdin)["hookSpecificOutput"]
sys.exit(0 if "permissionDecision" not in h and "additionalContext" in h else 1)'; then
  ok "MH_CODEX_QUOTA_DENY=0 keeps the old advisory-only behavior"
else bad "expected additionalContext with no permissionDecision under MH_CODEX_QUOTA_DENY=0, got '$out'"; fi

out=$(pretooluse_payload "npm test" | bash "$ADVISORY" "$S2")
if [ -z "$out" ]; then ok "a known reset never denies a non-codex command"
else bad "expected silence for a non-codex command, got '$out'"; fi

printf '{"recorded_at": %s, "reset_at": %s, "message": "Usage limit reached"}' "$(date +%s)" "$(( $(date +%s) - 10 ))" > "$S2"
out=$(pretooluse_payload "codex exec 'go'" | bash "$ADVISORY" "$S2")
if [ -z "$out" ] && [ ! -f "$S2" ]; then ok "a reset time already past clears the record and stays silent"
else bad "expected silence and a removed record once reset_at has passed, got out='$out' state_exists=$([ -f "$S2" ] && echo yes || echo no)"; fi

# --- the deny needs a real codex invocation; a command that only names the word still just advises ---
future_state "$S2"
for cmd in 'git commit -m "fix codex hook"' 'grep codex notes.md' 'echo codex' 'command -v codex'; do
  out=$(pretooluse_payload "$cmd" | bash "$ADVISORY" "$S2")
  if echo "$out" | grep -q '"permissionDecision": *"deny"'; then bad "a command that only mentions codex was denied: $cmd"
  else ok "a known reset does not deny a command that only mentions codex: $cmd"; fi
done
for cmd in "cd /tmp && codex exec 'go'" "rtk proxy codex exec 'go'" "FOO=1 codex exec 'go'" "echo hi; codex exec 'go'" "node /p/codex-companion.mjs task go"; do
  out=$(pretooluse_payload "$cmd" | bash "$ADVISORY" "$S2")
  if echo "$out" | grep -q '"permissionDecision": *"deny"'; then ok "a known reset still denies a real invocation: $cmd"
  else bad "expected a deny for a real codex invocation: $cmd, got '$out'"; fi
done

# --- a reset still ahead outlives the advisory TTL (a weekly limit can be days out) ---
printf '{"recorded_at": %s, "reset_at": %s, "message": "Usage limit reached"}' "$(( $(date +%s) - 90000 ))" "$(( $(date +%s) + 172800 ))" > "$S2"
out=$(pretooluse_payload "codex exec 'go'" | bash "$ADVISORY" "$S2")
if echo "$out" | grep -q '"permissionDecision": *"deny"'; then ok "a record older than the TTL still denies while its reset is ahead"
else bad "expected a deny for an old record with a future reset, got '$out'"; fi

echo
echo "codex-quota tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
