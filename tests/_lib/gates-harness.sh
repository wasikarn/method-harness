#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # gate paths are used by the files that source this
# gates-harness.sh: shared payload builders and assertions for tests/hooks/test-gates.sh,
# test-gates-irrecoverable-2.sh and test-gates-other.sh. The caller sets ROOT and sources this.
# Isolate the gate-verdict journal (hooks/gates/_journal.py) from this file's
# 165+ deny/ask assertions -- run standalone (this file's own header
# invites it), it would otherwise silently append rows to the operator's
# real ~/.local/share/kbg/metrics/gate-decisions.jsonl.
. "$ROOT/scripts/_lib/tmp-delete.sh"
_JOURNAL_TMP="$(mktemp -d)"
trap 'tmp_delete "$_JOURNAL_TMP"' EXIT
export MH_GATE_JOURNAL_PATH="$_JOURNAL_TMP/gate-decisions.jsonl"
IRRECOVERABLE="$ROOT/hooks/gates/irrecoverable.sh"
TASK_COMPLETE="$ROOT/hooks/gates/task-complete-separation.sh"
SUBAGENT_GIT_GUARD="$ROOT/hooks/gates/subagent-git-guard.sh"
SUBAGENT_SPAWN_GUARD="$ROOT/hooks/gates/subagent-spawn-guard.sh"
ROUTINE_TRIGGER_GUARD="$ROOT/hooks/gates/routine-trigger-guard.sh"

pass=0
fail=0

# Build a minimal Bash tool payload. The command is JSON-encoded by jq (not
# printf %s) so commands containing quotes/backslashes (e.g. mysql -e "DROP
# TABLE...", find -exec ... \;) don't produce malformed JSON that silently
# degrades to an empty command downstream; -a keeps non-ASCII as \uXXXX
# escapes, as json.dumps did. Piped via stdin, not argv: a GH #140-style
# oversized command (700k chars) as a literal exec() argument exceeds Linux's
# MAX_ARG_STRLEN (128 KiB per argument, a hard kernel cap absent on macOS),
# so the tool itself fails to exec with "Argument list too long" before ever
# reaching the gate under test -- confirmed live on Ubuntu 24.04. jq reads
# stdin, and the encoded string goes to the printf builtin (no exec), so
# neither step has that limit. jq starts faster than python3.
bash_payload() { printf '{"tool_name": "Bash", "tool_input": {"command": %s}}\n' "$(printf '%s' "$1" | jq -Rsa .)"; }

# Build a Write tool payload. Uses json.dumps (see bash_payload above) so
# content containing quotes/backslashes doesn't produce malformed JSON.
write_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))' "$1" "$2"
}

# Build an Edit tool payload. Same json.dumps rationale as write_payload.
edit_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], "new_string": sys.argv[2]}}))' "$1" "$2"
}

# Build a TaskUpdate payload. $1=status (or empty to omit the field),
# $2=agent_type (or empty = main session, field omitted). Uses json.dumps so
# the agent_type string is safely encoded.
taskupdate_payload() {
  python3 -c '
import json, sys
status, agent, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"taskId": "T1"}
if status:
    ti["status"] = status
d = {"tool_name": "TaskUpdate", "tool_input": ti}
if agent:
    d["agent_type"] = agent
if agent_id:
    d["agent_id"] = agent_id
print(json.dumps(d))
' "$1" "$2" "${3-$2}"
}

# Same shape as taskupdate_payload but the agent_id KEY is always forced
# present at an explicit value, including "" or JSON null -- taskupdate_payload
# above treats a falsy $3 as "omit the key" (main session shape), which cannot
# express "key present but empty/null" (GH #155: the .py gate's old `if not
# agent_id` check treated presence-with-empty/null the same as absence, same
# gap as GH #154 fixed in subagent-spawn-guard.py). $3 == "__NULL__" emits
# JSON null; anything else is used as the literal string value (including "").
taskupdate_payload_forced_id() {
  python3 -c '
import json, sys
status, agent, agent_id_raw = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"taskId": "T1"}
if status:
    ti["status"] = status
d = {"tool_name": "TaskUpdate", "tool_input": ti}
if agent:
    d["agent_type"] = agent
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2" "$3"
}

# Build a Bash tool-call payload carrying agent_id (or empty = main
# session). Separate from bash_payload() (used by many pre-existing tests
# with no agent fields at all) to avoid touching that signature.
bash_agent_payload() {
  python3 -c '
import json, sys
cmd, agent_id = sys.argv[1], sys.argv[2]
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
if agent_id:
    d["agent_id"] = agent_id
print(json.dumps(d))
' "$1" "$2"
}

# Build a Bash tool-call payload with the agent_id KEY forced present at an
# explicit value, including "" or JSON null (C1b, harness gap-audit
# 2026-09-20) -- mirrors agent_payload_forced_id() below for the Bash tool,
# needed because irrecoverable.py's two nested-spawn call sites (top-level
# command and the bash -c/eval unwrapped body) are gated on agent_id
# PRESENCE, not truthiness, and bash_agent_payload() above can't express
# "key present but empty/null" (it omits the key entirely when $2 is falsy).
# $2 == "__NULL__" emits JSON null; anything else is the literal string value.
bash_agent_payload_forced_id() {
  python3 -c '
import json, sys
cmd, agent_id_raw = sys.argv[1], sys.argv[2]
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2"
}

# Build an Agent tool-call payload. $1=subagent_type for the dispatch (tool_input),
# $2=agent_id of the CALLER (empty = main session), $3=agent_type of the caller
# (optional, for the deny message only — the gate's logic keys on agent_id, not
# this field, same distinction task-complete-separation.py documents).
agent_payload() {
  python3 -c '
import json, sys
subagent_type, agent_id, agent_type = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"tool_name": "Agent", "tool_input": {"prompt": "do work", "description": "task", "subagent_type": subagent_type}}
if agent_id:
    d["agent_id"] = agent_id
if agent_type:
    d["agent_type"] = agent_type
print(json.dumps(d))
' "$1" "$2" "${3-}"
}

# Build an Agent tool-call payload with the agent_id KEY forced present at an
# explicit value, including "" or JSON null -- agent_payload() above treats a
# falsy $2 as "omit the key" (main session shape), which cannot express
# "key present but empty/null" (GH #154 gap 2: the .py gate's old `if not
# agent_id` check treated presence-with-empty/null the same as absence).
# $2 == "__NULL__" emits JSON null; anything else is used as the literal string
# value (including "").
agent_payload_forced_id() {
  python3 -c '
import json, sys
subagent_type, agent_id_raw = sys.argv[1], sys.argv[2]
d = {"tool_name": "Agent", "tool_input": {"prompt": "do work", "description": "task", "subagent_type": subagent_type}}
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2"
}

# Build an Agent tool-call payload where the agent_id KEY is written as the
# JSON _ escape for the underscore (agent_id) instead of a literal
# underscore -- valid JSON decoding to the key "agent_id", but the RAW text
# never contains the substring "agent_id" (GH #154 gap 1: the .sh gate's old
# bash fast-path was a raw-text substring match performed before any JSON
# parsing, so an escaped key silently bypassed it). Built with chr(92) rather
# than a literal backslash so the escape survives untouched through argv/tool
# transports that would otherwise decode _ before it reaches this script.
agent_payload_escaped_id_key() {
  python3 -c '
key = "agent" + chr(92) + "u005f" + "id"
print("{\"tool_name\": \"Agent\", \"tool_input\": {\"prompt\": \"do work\", "
      "\"description\": \"task\", \"subagent_type\": \"general-purpose\"}, \"" + key + "\": \"agent-1\"}")
'
}

# Build a RemoteTrigger or CronCreate tool-call payload ($1 = tool name).
# $1 = tool name. $2 = action (optional -- omitted means no "action" key at all,
# to test the missing-action path separately from an empty/unrecognized one).
routine_trigger_payload() {
  if [ "$#" -ge 2 ]; then
    python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"action": sys.argv[2]}}))' "$1" "$2"
  else
    python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {}}))' "$1"
  fi
}

# Expect the gate to BLOCK (exit 2) by its own decision. A fail-closed wrapper (irrecoverable.sh) turns
# a Python crash into exit 2 too, which once hid a TypeError from every deny row (GH #245), so a
# Traceback or "internal error" on stderr fails the row.
_ERRF="$_JOURNAL_TMP/stderr"  # cleaned by the EXIT trap above
test_deny() {
  local gate="$1" desc="$2" payload="$3"
  local rc
  rc=$(echo "$payload" | bash "$gate" 2>"$_ERRF"; echo $?)
  if /usr/bin/grep -qE 'Traceback|internal error' "$_ERRF"; then
    echo "  ❌ DENY came from a crash, not the gate's own rule: $desc ($(tail -1 "$_ERRF"))" >&2
    fail=$((fail + 1))
  elif [[ "$rc" != "2" ]]; then
    echo "  ❌ DENY EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  elif [ -n "${_DENY_SAYS:-}" ] && ! /usr/bin/grep -qF -- "$_DENY_SAYS" "$_ERRF"; then
    echo "  ❌ DENY naming '$_DENY_SAYS' EXPECTED ($(tail -1 "$_ERRF")): $desc" >&2
    fail=$((fail + 1))
  elif [ -n "${_DENY_NOT:-}" ] && /usr/bin/grep -qF -- "$_DENY_NOT" "$_ERRF"; then
    echo "  ❌ DENY must not name '$_DENY_NOT' ($(tail -1 "$_ERRF")): $desc" >&2
    fail=$((fail + 1))
  else
    echo "  ✅ DENY${_DENY_SAYS:+ ($_DENY_SAYS)}: $desc"
    pass=$((pass + 1))
  fi
}

# test_deny, plus the stderr reason must contain <needle> (the next step a refusal names) and,
# when given, must not contain <absent>.
test_deny_says() { _DENY_SAYS="$4" _DENY_NOT="${5:-}" test_deny "$1" "$2" "$3"; }

# Expect exit 2 FROM the fail-closed wrapper after an internal error: the one case test_deny rejects.
test_deny_failclosed() {
  local gate="$1" desc="$2" payload="$3"
  local rc
  rc=$(echo "$payload" | bash "$gate" 2>"$_ERRF"; echo $?)
  if [[ "$rc" == "2" ]] && /usr/bin/grep -q 'internal error' "$_ERRF"; then
    echo "  ✅ DENY (fail-closed): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ FAIL-CLOSED DENY EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# deepen <n>: the JSON object on stdin plus one extra key nested <n> arrays deep. Depth 1000000
# overflows json.load (RecursionError) on every Python; depth 500 parses everywhere (<=3.11 overflows
# near 986). Fed through echo by the test_* helpers, so no exec argument-size limit applies.
deepen() {
  python3 -c 'import sys; s = sys.stdin.read().rstrip(); n = int(sys.argv[1]); print(s[:-1] + ", \"x\": " + "[" * n + "]" * n + "}")' "$1"
}

# GATE_RUNNER=memerr (tests/_lib/memerr.sh) runs test_deny_deep/test_ask with json.load raising MemoryError.
. "$(dirname "${BASH_SOURCE[0]}")/memerr.sh"

# Expect the depth-overflow fail-closed deny: exit 2 AND the "nested too deep" stderr line, so neither a
# crash nor the gate's ordinary rule can pass the row.
test_deny_deep() {
  local gate="$1" desc="$2" payload="$3"
  local rc
  rc=$(echo "$payload" | ${GATE_RUNNER:-bash} "$gate" 2>"$_ERRF"; echo $?)
  if [[ "$rc" == "2" ]] && /usr/bin/grep -q 'nested too deep' "$_ERRF"; then
    echo "  ✅ DENY (too deep): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ DEPTH DENY EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# Expect the gate to ALLOW (exit 0 + empty stdout — no permissionDecision JSON).
test_allow() {
  local gate="$1" desc="$2" payload="$3" envvar="${4:-}"
  local rc
  if [ -n "$envvar" ]; then
    rc=$(echo "$payload" | env "$envvar" bash "$gate" 2>/dev/null; echo $?)
  else
    rc=$(echo "$payload" | bash "$gate" 2>/dev/null; echo $?)
  fi
  if [[ "$rc" == "0" ]]; then
    echo "  ✅ ALLOW${envvar:+ (env)}: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ ALLOW EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# Expect the gate to ASK (exit 0 + permissionDecision: ask JSON on stdout).
test_ask() {
  local gate="$1" desc="$2" payload="$3"
  local out rc
  out=$(echo "$payload" | ${GATE_RUNNER:-bash} "$gate" 2>/dev/null); rc=$?
  # stdout must be exactly ONE JSON object: two concatenated objects are not valid JSON (GH #254 validator).
  if [[ "$rc" == "0" ]] && printf '%s' "$out" | python3 -c 'import json,sys; assert json.loads(sys.stdin.read())["hookSpecificOutput"]["permissionDecision"] == "ask"' 2>/dev/null; then
    echo "  ✅ ASK: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ ASK EXPECTED but got exit $rc out='$out': $desc" >&2
    fail=$((fail + 1))
  fi
}

# test_ask, plus the reason must contain <needle>: the gate emits only its first ask, so the
# reason names which rule fired.
test_ask_says() {
  local gate="$1" desc="$2" payload="$3" needle="$4"
  local out rc
  out=$(echo "$payload" | ${GATE_RUNNER:-bash} "$gate" 2>/dev/null); rc=$?
  if [[ "$rc" == "0" ]] && printf '%s' "$out" | NEEDLE="$needle" python3 -c 'import json,os,sys; o=json.loads(sys.stdin.read())["hookSpecificOutput"]; assert o["permissionDecision"] == "ask" and os.environ["NEEDLE"] in o["permissionDecisionReason"]' 2>/dev/null; then
    echo "  ✅ ASK ($needle): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ ASK naming '$needle' EXPECTED but got exit $rc out='$out': $desc" >&2
    fail=$((fail + 1))
  fi
}

# Fix C appends one window per action flag: a flood of -exec words, or nested `find -exec find`, must
# stay inside the gate's own 8s hook timeout (the deny must not arrive after the budget).
_timed_case() {  # <name> <expected rc> <command>
  local name="$1" want="$2" cmd="$3" t0 rc t1
  t0=$(date +%s)
  bash_payload "$cmd" | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; rc=$?
  t1=$(( $(date +%s) - t0 ))
  if [[ "$rc" == "$want" ]] && [ "$t1" -le 4 ]; then
    echo "  ✅ $name (rc=$rc in ${t1}s)"; pass=$((pass + 1))
  else
    echo "  ❌ $name: expected rc=$want within 4s, got rc=$rc in ${t1}s" >&2; fail=$((fail + 1))
  fi
}

_ratio_now() { python3 -c 'import time; print(time.monotonic())'; }

# irrecoverable.sh's hook timeout from hooks/hooks.json into _HOOK_CEIL (past it the hook allows). On a
# failure it counts the row failed and returns 1, so it is called bare, never in $(...), which would drop
# the count: `_hook_ceiling "$name" || return`.
_hook_ceiling() {  # <row name>
  local name="$1" ceil jerr probe
  _HOOK_CEIL=""
  # a trial run, not `command -v`: a jq on PATH that cannot run (a wrong-architecture binary), or some other
  # program named jq, does not print 3 for 1+2 (one trailing "\r" is dropped: a Windows jq ends lines "\r\n")
  probe=$(jq -n '1+2' 2>/dev/null)
  if [ "${probe%$'\r'}" != 3 ]; then
    echo "  ❌ $name: jq is missing, will not run, or is not jq, so the irrecoverable.sh timeout cannot be read from hooks/hooks.json" >&2
    fail=$((fail + 1)); return 1
  fi
  # stderr apart from the value, so a jq warning on a good read cannot end up in the ceiling
  if ! ceil=$(jq -r '[.. | objects | select((.command? // "") | test("gates/irrecoverable\\.sh")) | .timeout]
    | if length == 1 and (.[0] | type) == "number" then .[0] else empty end' "$ROOT/hooks/hooks.json" 2>"$_ERRF"); then
    jerr=$(head -1 "$_ERRF"); jerr=${jerr%$'\r'}
    echo "  ❌ $name: jq could not read the irrecoverable.sh timeout from hooks/hooks.json (${jerr:-jq printed no error})" >&2
    fail=$((fail + 1)); return 1
  fi
  ceil=${ceil%$'\r'}  # the same Windows "\r", before the empty check so a lone "\r" counts as no value
  if [ -z "$ceil" ]; then
    echo "  ❌ $name: no single numeric irrecoverable.sh timeout in hooks/hooks.json" >&2; fail=$((fail + 1)); return 1
  fi
  _HOOK_CEIL=$ceil
}

# GH #789: a row whose regression runs well past the hook timeout is timed against that timeout itself,
# sub-second, not a fixed 4 s, so a slower host keeps its headroom. The regressions of the rows using it took
# 15 s to over 40 s on a 4-core host, so they still fail on a host up to about twice as fast. A timing miss is
# measured once more before it fails, as in _timed_ratio_case below.
_timed_hook_case() {  # <name> <expected rc> <command>
  local name="$1" want="$2" cmd="$3" ceil t0 t1 rc secs ok try seen=""
  _hook_ceiling "$name" || return
  ceil=$_HOOK_CEIL
  for try in 1 2; do
    t0=$(_ratio_now)
    bash_payload "$cmd" | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; rc=$?
    t1=$(_ratio_now)
    read -r secs ok < <(python3 -c 'import sys
a, b, cap = map(float, sys.argv[1:])
print("%.2f %d" % (b - a, b - a < cap))' "$t0" "$t1" "$ceil")
    secs=${secs:-?} ok=${ok:-0}
    seen="$seen${seen:+, then }rc=$rc in ${secs}s"
    [[ "$rc" == "$want" ]] || break
    [[ "$ok" == 1 ]] && break
  done
  if [[ "$rc" == "$want" && "$ok" == 1 ]]; then
    echo "  ✅ $name (rc=$rc in ${secs}s, under ${ceil}s)"; pass=$((pass + 1))
  else
    echo "  ❌ $name: expected rc=$want under ${ceil}s, got $seen" >&2; fail=$((fail + 1))
  fi
}

# GH #761: a cost that must not grow with some factor (nesting depth) is checked against a baseline of
# the same size run on the same machine, so the budget does not depend on how fast the host is. Timed in
# python3, as BSD `date` has no %N; its start-up cost falls on both runs alike. Load that lands on one run
# only skews the ratio, so a timing miss is measured once more before it fails (a wrong rc fails at once,
# as it does not depend on timing). The command must also finish under the gate's hook timeout (read from
# hooks/hooks.json), past which the hook allows: a slowdown both runs share keeps the ratio.
_timed_ratio_case() {  # <name> <expected rc> <max ratio> <baseline command> <command>
  local name="$1" want="$2" max="$3" base="$4" cmd="$5" t0 t1 t2 rc brc ratio secs ok try ceil seen=""
  _hook_ceiling "$name" || return
  ceil=$_HOOK_CEIL
  for try in 1 2; do
    t0=$(_ratio_now)
    bash_payload "$base" | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; brc=$?
    t1=$(_ratio_now)
    bash_payload "$cmd" | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; rc=$?
    t2=$(_ratio_now)
    read -r ratio secs ok < <(python3 -c 'import sys
a, b, c, m, cap = map(float, sys.argv[1:]); r = (c - b) / max(b - a, 0.01)
print("%.2f %.2f %d" % (r, c - b, r <= m and c - b < cap))' "$t0" "$t1" "$t2" "$max" "$ceil")
    ratio=${ratio:-?} secs=${secs:-?} ok=${ok:-0}
    seen="$seen${seen:+, then }rc=$rc (baseline rc=$brc) in ${secs}s at ${ratio}x"
    [[ "$rc" == "$want" && "$brc" == "$want" ]] || break
    [[ "$ok" == 1 ]] && break
  done
  if [[ "$rc" == "$want" && "$brc" == "$want" && "$ok" == 1 ]]; then
    echo "  ✅ $name (rc=$rc in ${secs}s, ${ratio}x the baseline)"; pass=$((pass + 1))
  else
    echo "  ❌ $name: expected rc=$want under ${ceil}s and within ${max}x the baseline, got $seen" >&2
    fail=$((fail + 1))
  fi
}

# 100 -C globals: used by GH #255 rows in test-gates-irrecoverable-2.sh and eval rows in test-gates-other.sh.
_many_c=$(printf -- '-C . %.0s' $(seq 100))

gates_summary() {
  echo ""
  local total=$((pass + fail))
  echo "=== $pass/$total passed ==="
  [[ "$fail" -eq 0 ]]
}
