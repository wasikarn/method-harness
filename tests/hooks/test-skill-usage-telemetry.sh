#!/usr/bin/env bash
# skill-usage-telemetry unit tests (#90/T11): simulates PostToolUse(Skill)
# payloads and asserts one compact JSONL row lands per invocation with
# {ts, session_id, skill, plugin} — no outcome/success field (see the hook's
# own header for why: no reliable success signal exists for a Skill call).
# Restored 2026-09-20 (harness gap-audit H9) after deletion in a1055f64.
# Run standalone: bash tests/hooks/test-skill-usage-telemetry.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
HOOK="$ROOT/hooks/session/skill-usage-telemetry.sh"

pass=0
fail=0

TMP_HOME="$(mktemp -d)"
trap 'tmp_delete "$TMP_HOME"' EXIT
LOG_FILE="$TMP_HOME/.local/share/kbg/metrics/skill-usage.jsonl"

run_hook() {
  local payload="$1"
  HOME="$TMP_HOME" bash -c "echo '$payload' | '$HOOK'"
}

echo "=== skill-usage-telemetry hook (PostToolUse: Skill) ==="
echo ""

payload='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"mh:harness-audit"}}'
run_hook "$payload" >/tmp/sut-stdout.$$ 2>/tmp/sut-stderr.$$
rc=$?
stdout_content=$(cat /tmp/sut-stdout.$$)
rm -f /tmp/sut-stdout.$$ /tmp/sut-stderr.$$

if [[ "$rc" == "0" && -z "$stdout_content" ]]; then
  echo "  ✅ SILENT + exit 0: mh: skill invocation"
  pass=$((pass + 1))
else
  echo "  ❌ expected silent exit 0 but rc=$rc stdout=<$stdout_content>" >&2
  fail=$((fail + 1))
fi

if [[ -f "$LOG_FILE" ]] && jq -e '.skill == "mh:harness-audit" and .plugin == "mh" and .session_id == "sess-1"' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ LOGGED: row has correct skill/plugin/session_id"
  pass=$((pass + 1))
else
  echo "  ❌ LOG MISMATCH: expected a row with skill=mh:harness-audit plugin=mh" >&2
  fail=$((fail + 1))
fi

if jq -e 'has("outcome") | not' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ NO OUTCOME FIELD: schema is invocation-count-only, per the #90 scope decision"
  pass=$((pass + 1))
else
  echo "  ❌ row unexpectedly carries an outcome field — this schema was deliberately dropped" >&2
  fail=$((fail + 1))
fi

payload2='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"mattpocock-skills:code-review"}}'
run_hook "$payload2" >/dev/null 2>&1
if [[ "$(wc -l <"$LOG_FILE" | tr -d ' ')" == "2" ]] && jq -e 'select(.skill == "mattpocock-skills:code-review") | .plugin == "mattpocock-skills"' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ APPENDS + PLUGIN SPLIT: second invocation adds a row, plugin derived from the skill's namespace prefix"
  pass=$((pass + 1))
else
  echo "  ❌ expected 2 rows with correct plugin split, got $(wc -l <"$LOG_FILE" | tr -d ' ') lines" >&2
  fail=$((fail + 1))
fi

payload3='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{}}'
run_hook "$payload3" >/dev/null 2>&1
if jq -e 'select(.skill == "unknown") | .plugin == "unnamespaced"' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ MISSING FIELD FALLBACK: no tool_input.skill -> skill 'unknown', plugin 'unnamespaced', still appends"
  pass=$((pass + 1))
else
  echo "  ❌ missing tool_input.skill should fall back to skill=unknown plugin=unnamespaced" >&2
  fail=$((fail + 1))
fi

# Adversarial fixes (2026-08-25, #90 independent review): tool_input.skill
# present but the WRONG type used to throw inside split(":") -- a jq error
# swallowed by 2>/dev/null, silently DROPPING the row entirely rather than
# falling back to "unknown" like the missing-key case does.
payload_badtype='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":42}}'
lines_before=$(wc -l <"$LOG_FILE" | tr -d ' ')
run_hook "$payload_badtype" >/dev/null 2>&1
lines_after=$(wc -l <"$LOG_FILE" | tr -d ' ')
if [[ "$lines_after" == "$((lines_before + 1))" ]] && jq -e 'select(.skill == "unknown" and .plugin == "unnamespaced")' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ WRONG-TYPE SKILL: a non-string tool_input.skill (a number) still appends a row (skill=unknown), not silently dropped"
  pass=$((pass + 1))
else
  echo "  ❌ a non-string tool_input.skill should append a fallback row, not vanish silently (before=$lines_before after=$lines_after)" >&2
  fail=$((fail + 1))
fi

# Unnamespaced skill (no ":" at all -- several real skills in this fleet
# have no plugin prefix, e.g. "design", "run", "init"). Previously fell
# through split(":")[0] to plugin == skill, showing up in the health panel
# as its own fake single-skill "plugin".
payload_unnamespaced='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"design"}}'
run_hook "$payload_unnamespaced" >/dev/null 2>&1
if jq -e 'select(.skill == "design") | .plugin == "unnamespaced"' "$LOG_FILE" >/dev/null 2>&1; then
  echo "  ✅ UNNAMESPACED SKILL: a colon-free skill name reports plugin='unnamespaced', not plugin==skill"
  pass=$((pass + 1))
else
  echo "  ❌ an unnamespaced skill name should report plugin='unnamespaced', not collapse plugin==skill" >&2
  fail=$((fail + 1))
fi

# (2026-09-21 deep-audit) tool_input present but NOT an object (a string) used
# to make `.tool_input.skill?` yield nothing, so the row vanished -- against
# the hook's own "every malformed path -> unknown" comment. Line count +1 and
# the LAST row must be the fallback shape (earlier cases already logged
# unknown rows, so a bare select() would pass regardless).
payload_badinput='{"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":"design"}'
lines_before=$(wc -l <"$LOG_FILE" | tr -d ' ')
run_hook "$payload_badinput" >/dev/null 2>&1
lines_after=$(wc -l <"$LOG_FILE" | tr -d ' ')
if [[ "$lines_after" == "$((lines_before + 1))" ]] && tail -1 "$LOG_FILE" | jq -e '.skill == "unknown" and .plugin == "unnamespaced" and .session_id == "sess-1"' >/dev/null 2>&1; then
  echo "  ✅ NON-OBJECT tool_input: a string tool_input still appends a skill=unknown/plugin=unnamespaced row, not silently dropped"
  pass=$((pass + 1))
else
  echo "  ❌ a non-object tool_input should append a fallback row, not vanish silently (before=$lines_before after=$lines_after last=$(tail -1 "$LOG_FILE"))" >&2
  fail=$((fail + 1))
fi

# GH #330: rows say where the call came from. A model Skill call is
# source "tool"; a user-typed /skill never makes a Skill call, so it is caught
# on UserPromptExpansion instead and logged as source "typed".
if tail -1 "$LOG_FILE" | jq -e '.source == "tool"' >/dev/null 2>&1; then
  echo "  ✅ SOURCE TOOL: a PostToolUse(Skill) row carries source=tool"
  pass=$((pass + 1))
else
  echo "  ❌ a PostToolUse(Skill) row should carry source=tool, got $(tail -1 "$LOG_FILE")" >&2
  fail=$((fail + 1))
fi

payload_typed='{"session_id":"sess-2","hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"mh:memory-lint","command_args":"","command_source":"plugin","prompt":"/mh:memory-lint"}'
run_hook "$payload_typed" >/dev/null 2>&1
if tail -1 "$LOG_FILE" | jq -e '.skill == "mh:memory-lint" and .plugin == "mh" and .source == "typed" and .session_id == "sess-2"' >/dev/null 2>&1; then
  echo "  ✅ SOURCE TYPED: a UserPromptExpansion slash_command appends a source=typed row"
  pass=$((pass + 1))
else
  echo "  ❌ a typed /mh:memory-lint should append a source=typed row, got $(tail -1 "$LOG_FILE")" >&2
  fail=$((fail + 1))
fi

payload_mcp='{"session_id":"sess-2","hook_event_name":"UserPromptExpansion","expansion_type":"mcp_prompt","command_name":"srv:prompt","command_args":"","prompt":"/srv:prompt"}'
lines_before=$(wc -l <"$LOG_FILE" | tr -d ' ')
run_hook "$payload_mcp" >/dev/null 2>&1
lines_after=$(wc -l <"$LOG_FILE" | tr -d ' ')
if [[ "$lines_after" == "$lines_before" ]]; then
  echo "  ✅ MCP PROMPT SKIPPED: an mcp_prompt expansion is not a skill, no row"
  pass=$((pass + 1))
else
  echo "  ❌ an mcp_prompt expansion should not append a row" >&2
  fail=$((fail + 1))
fi

# GH #330: a short name the model passes is mapped to its namespaced form
# when exactly one installed plugin ships it; a name two plugins share, or a
# name a user-level skill owns, stays as-is. Fake plugin cache under TMP_HOME.
PLUG="$TMP_HOME/.claude/plugins"
mkdir -p "$PLUG/a/skills/grilling" "$PLUG/a/skills/doctor" "$PLUG/b/skills/doctor" \
  "$PLUG/b/nested/bucket/deep-one" "$PLUG/a/skills/mine" "$TMP_HOME/.claude/skills/mine" "$PLUG/b/.claude-plugin"
touch "$PLUG/a/skills/grilling/SKILL.md" "$PLUG/a/skills/doctor/SKILL.md" "$PLUG/b/skills/doctor/SKILL.md" \
  "$PLUG/b/nested/bucket/deep-one/SKILL.md" "$PLUG/a/skills/mine/SKILL.md"
printf '{"name":"plugb","skills":["./nested/bucket/"]}' > "$PLUG/b/.claude-plugin/plugin.json"
printf '{"version":2,"plugins":{"pluga@m":[{"installPath":"%s"}],"x@m":[{"installPath":"%s"}]}}' \
  "$PLUG/a" "$PLUG/b" > "$PLUG/installed_plugins.json"
check_mapped() {
  local short="$1" want="$2" label="$3"
  run_hook "{\"session_id\":\"sess-3\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$short\"}}" >/dev/null 2>&1
  if tail -1 "$LOG_FILE" | jq -e --arg w "$want" '.skill == $w and .source == "tool"' >/dev/null 2>&1; then
    echo "  ✅ $label"
    pass=$((pass + 1))
  else
    echo "  ❌ $label: expected skill=$want, got $(tail -1 "$LOG_FILE")" >&2
    fail=$((fail + 1))
  fi
}
check_mapped grilling "pluga:grilling" "SHORT NAME MAPPED: one plugin ships it -> namespaced, plugin name from the install key"
check_mapped deep-one "plugb:deep-one" "MANIFEST SKILLS ENTRY: a skill under a plugin.json bucket maps, name from plugin.json"
check_mapped doctor "doctor" "AMBIGUOUS KEPT: two plugins ship it -> stays short"
check_mapped mine "mine" "USER SKILL KEPT: a ~/.claude/skills entry owns the short name"
if tail -1 "$LOG_FILE" | jq -e '.plugin == "unnamespaced"' >/dev/null 2>&1; then
  echo "  ✅ UNMAPPED PLUGIN FIELD: a kept short name still reports plugin=unnamespaced"
  pass=$((pass + 1))
else
  echo "  ❌ a kept short name should report plugin=unnamespaced" >&2
  fail=$((fail + 1))
fi

# Malformed payload must not crash the hook or corrupt the log.
run_hook 'not json' >/tmp/sut-stdout2.$$ 2>/tmp/sut-stderr2.$$
rc=$?
rm -f /tmp/sut-stdout2.$$ /tmp/sut-stderr2.$$
if [[ "$rc" == "0" ]]; then
  echo "  ✅ EXIT 0: malformed payload doesn't crash the hook"
  pass=$((pass + 1))
else
  echo "  ❌ malformed payload exited $rc, expected 0" >&2
  fail=$((fail + 1))
fi

# $HOME guard (2026-09-20 restore, M8's sibling fix): unset/relative HOME
# must not resolve the log into the cwd or crash the hook.
lines_before=$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')
out=$(env -u HOME bash -c "echo '$payload' | '$HOOK'" 2>&1)
rc=$?
lines_after=$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')
if [[ "$rc" == "0" && -z "$out" && "$lines_after" == "$lines_before" ]]; then
  echo "  ✅ HOME GUARD: unset HOME exits 0 silently, does not touch the real \$TMP_HOME log"
  pass=$((pass + 1))
else
  echo "  ❌ unset HOME should exit 0 silently without touching the log (rc=$rc out=<$out> before=$lines_before after=$lines_after)" >&2
  fail=$((fail + 1))
fi

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
