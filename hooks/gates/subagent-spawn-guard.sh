#!/usr/bin/env bash
# Gate: a subagent (agent_id in the PreToolUse payload) may not call the Agent
# tool to spawn its own reviewer/validator/subagent (GH #151) -- dispatch is
# the main session's job (maker != checker, docs/METHODOLOGY.md Rule 13).
# Keys on agent_id (present ONLY inside a subagent call), not agent_type
# (also set for a top-level `claude --agent <name>` main session -- see
# task-complete-separation.py's header for the incident that taught this
# distinction). Unconditional across subagent_type: closes the same-type-
# switch evasion seen in the fork-recursive-spawn incident (2026-08-31),
# since the check never inspects tool_input.subagent_type at all.
# No bash-level fast path: a prior raw-text substring check on the agent_id
# key ran before any JSON parsing and could be bypassed by writing that key
# with a JSON unicode escape instead of a literal underscore -- valid JSON,
# same decoded key, but absent from the raw text the substring check saw
# (GH #154). Every payload now always reaches python3, matching the sibling
# gate task-complete-separation.sh's convention.
set -uo pipefail

# Portability guard (#93): announced fail-open when python3 is missing.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — subagent-spawn-guard gate cannot run; allowing (install python3 to restore maker/checker separation)" >&2
  exit 0
fi

_input=$(cat)

_py="$(dirname "$0")/subagent-spawn-guard.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script subagent-spawn-guard.py missing or unreadable — allowing (fail-safe = allow, same posture as this gate's ordinary parse-error path)" >&2
  exit 0
fi

printf '%s' "$_input" | python3 -S "$_py"  # -S: skip site import (stdlib-only gate)
exit $?
