#!/usr/bin/env bash
# PostToolUse(Skill) + UserPromptExpansion: journal each skill invocation,
# model-called (source "tool") or user-typed (source "typed"), to
# ~/.local/share/kbg/metrics/skill-usage.jsonl — usage evidence (not "feel")
# for the future matt-skill vs harness-skill overlap cull (#90/T11). This
# event has no decision control here — audit logging only, never a gate.
#
# Scope note (2026-08-25 operator decision): records invocation counts only,
# no outcome/success field. No reliable success signal exists for a Skill
# call — it loads instructions into context, it doesn't return an inspectable
# result the way a Bash exit code does — and docs don't confirm PostToolUse
# even defines one for this tool. Fabricating a constant "outcome" just to
# satisfy a schema would be a false metric, not a health signal.
#
# Restored 2026-09-20 (harness gap-audit H9) after deletion in a1055f64; the
# $HOME guard below is new, ported from hooks/gates/_journal.py's pattern
# after the same failure class was found and fixed elsewhere in this pass
# (hooks/stop/cost-tracker.sh's M8).
#
# ponytail: unbounded append, same precedent as hooks/stop/cost-tracker.sh — rotate/trim manually if it grows large.
set -uo pipefail

payload=$(cat)

if [ -z "${HOME:-}" ] || [[ "$HOME" != /* ]]; then
  exit 0
fi

log_dir="$HOME/.local/share/kbg/metrics"
mkdir -p "$log_dir"

# Two adversarial-audit fixes (2026-08-25, #90 independent review):
#   - tool_input.skill can be present but the WRONG type (a number, an
#     object) rather than merely missing/null; `// "unknown"` alone only
#     covers missing/null, so a wrong-typed value used to throw inside
#     `split(":")` -- a jq error swallowed by 2>/dev/null, silently
#     DROPPING the row entirely instead of falling back to "unknown" like
#     every other malformed-input path here does. Now type-checked first.
#   - an unnamespaced skill (no ":" at all -- several real skills in this
#     fleet have no plugin prefix) used to fall through split(":")[0] and
#     report plugin == skill, showing up in the health panel as its own
#     fake single-skill "plugin". Now reported as "unnamespaced" instead.
# `.tool_input.skill?` on a non-object tool_input yields NOTHING (not null), so
# the whole program used to emit no row (2026-09-21). `// null` turns that
# empty into null and the value is bound once, never re-indexed.
#
# GH #330: a user-typed /skill never makes a Skill tool call, so this hook is
# also registered on UserPromptExpansion (source "typed"), whose command_name
# is the resolved, namespaced name. Only slash_command expansions are skills;
# mcp_prompt ones are skipped. A model call (source "tool") can pass a short
# name ("grilling") that the tool result keeps short too, so a colon-free
# name is mapped by scripts/_lib/skill-namespace.py when exactly one
# installed plugin ships it; an ambiguous or unknown name stays as-is.
# One jq pass for event, expansion type and short name (was three spawns),
# NUL-separated so a name with a newline or tab can't shift the fields.
event="" exptype="" short=""
{
  IFS= read -r -d '' event
  IFS= read -r -d '' exptype
  IFS= read -r -d '' short
} < <(jq -j '
  (.hook_event_name // "" | tostring) + "\u0000" +
  (.expansion_type // "" | tostring) + "\u0000" +
  ((if .hook_event_name == "UserPromptExpansion" then "" else (.tool_input.skill? // "") end | if type == "string" then . else "" end) // "") + "\u0000"
' <<<"$payload" 2>/dev/null)
case "$event" in
  UserPromptExpansion)
    [ "$exptype" = "slash_command" ] || exit 0
    source=typed ;;
  *) source=tool ;;
esac
mapped=""
resolver="$(dirname "$0")/../../scripts/_lib/skill-namespace.py"
if [ -n "$short" ] && [[ "$short" != *:* ]] && command -v python3 >/dev/null 2>&1 && [ -r "$resolver" ]; then
  mapped=$(python3 "$resolver" "$short" 2>/dev/null) || mapped=""
fi
jq -c --arg src "$source" --arg mapped "$mapped" '
  (now | strftime("%Y-%m-%dT%H:%M:%SZ")) as $ts |
  (if $src == "typed" then .command_name? else .tool_input.skill? end // null) as $raw |
  (if $mapped != "" then $mapped
   elif ($raw | type) == "string" and ($raw | length) > 0
   then $raw else "unknown" end) as $skill |
  {
    ts: $ts,
    session_id: (.session_id // "unknown"),
    skill: $skill,
    plugin: (if ($skill | contains(":")) then ($skill | split(":")[0]) else "unnamespaced" end),
    source: $src
  }
' <<<"$payload" >>"$log_dir/skill-usage.jsonl" 2>/dev/null

exit 0
