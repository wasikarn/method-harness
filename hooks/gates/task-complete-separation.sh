#!/usr/bin/env bash
# Gate: a subagent may not mark its own task completed (maker≠checker).
# Reads the PreToolUse JSON payload from stdin; exits 2 to block.
#
# Why: the builder → validator chain (METHODOLOGY.md Rule 13) was
# enforced by prompt doctrine + TaskCreate/addBlockedBy ordering only —
# addBlockedBy gates *ordering*, but nothing computationally stopped the maker
# from marking its own task `completed` without the validator's pass. That is
# the maker-grading-its-own-work circularity the harness exists to forbid.
# Native CC (v2.1.142+) fires PreToolUse inside subagents with `agent_id`
# present (docs-confirmed against code.claude.com/docs/en/hooks, corrected
# 2026-08-31: an earlier version of this gate keyed on `agent_type`, which is
# ALSO set for a top-level `claude --agent <name>` main session — a real
# security-review finding), so the gate can tell an actual subagent from the
# main session without an artifact file or an allowlist.
#
# Rule: deny TaskUpdate(status="completed") whenever `agent_id` is present
# (any subagent). The main session (no `agent_id`, whether or not it was
# started with --agent) owns completion — it is the operator proxy and the
# trusted verifier of last resort. Validator subagents return verdicts to
# the main session; the main session marks completed. A subagent's agent_id
# is fixed at spawn and cannot be mutated, so a maker literally cannot call
# TaskUpdate(completed).
set -uo pipefail

# Portability guard (#93): announced fail-open when python3 is missing;
# doctrine-bootstrap.sh names the missing dep once at SessionStart.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — task-complete-separation gate cannot run; allowing (install python3 to restore maker/checker separation)" >&2
  exit 0
fi

_py="$(dirname "$0")/task-complete-separation.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script task-complete-separation.py missing or unreadable — allowing (fail-safe = allow, same posture as this gate's ordinary parse-error path)" >&2
  exit 0
fi

python3 -S "$_py"  # -S: skip site import (stdlib-only gate)
exit $?
