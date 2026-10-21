#!/usr/bin/env bash
# Wrapper for gate:agent:subagent-verdict-check (SubagentStop) and
# gate:agent:subagent-verdict-check-handback (PreToolUse on SubagentHandback)
# -- see subagent-verdict-gate.py for the actual check; it dispatches on
# hook_event_name. Fail-open posture matches this repo's other
# subagent-scoped gates: a missing python3 must never block a subagent's
# own Stop or its SubagentHandback call, only forgo the extra verdict-shape
# check that would have run this turn.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] subagent-verdict-check: python3 missing, allowing (no verdict-shape check this turn)" >&2
  exit 0
fi

_py="$DIR/subagent-verdict-gate.py"
if [ ! -r "$_py" ]; then
  # A python3 "no such file" exit code (commonly 2) would otherwise be
  # misread by Claude Code as an explicit block -- exit 2 blocks on both
  # SubagentStop and PreToolUse -- so this must be checked before exec, matching
  # subagent-spawn-guard.sh's/task-complete-separation.sh's convention.
  echo "[mh:gate] internal error: sibling script subagent-verdict-gate.py missing or unreadable — allowing" >&2
  exit 0
fi

exec python3 -S "$_py"  # -S: skip site import (stdlib-only gate)
