#!/usr/bin/env bash
# Gate: ask-tier confirmation before RemoteTrigger creates, updates, runs, or
# wires a webhook onto a Routine (a cloud session). Closes the gap ADR 0004
# names in its own [R1 fix] to §4 ("nothing gates the model from creating or
# firing a Routine in the first place") -- matches Phase B's `gh pr merge`
# ask-tier rule in irrecoverable.py in shape and posture (ask, not deny: a
# legitimate, operator-approved action). CronCreate is out of scope (mh:deep-
# audit, 2026-09-28): it only re-enqueues a prompt in this same, already-
# attended session -- see routine-trigger-guard.py for the full rationale.
set -uo pipefail

# Portability guard (#93): announced fail-open when python3 is missing.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — routine-trigger-guard gate cannot run; allowing (install python3 to restore the ask-tier confirmation)" >&2
  exit 0
fi

_input=$(cat)

_py="$(dirname "$0")/routine-trigger-guard.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script routine-trigger-guard.py missing or unreadable — allowing (fail-safe = allow, same posture as this gate's ordinary parse-error path)" >&2
  exit 0
fi

printf '%s' "$_input" | python3 -S "$_py"  # -S: skip site import (stdlib-only gate)
exit $?
