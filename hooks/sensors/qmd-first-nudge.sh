#!/usr/bin/env bash
# Sensor: on a thread's first WebSearch or Firecrawl search (main thread or subagent) with
# no earlier qmd call in the session, inject a qmd-first nudge (additionalContext) and log
# one row per thread. Advisory only -- never denies, never blocks; always exits 0.
set -uo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:sensor] python3 not found — qmd-first-nudge cannot run; allowing (install python3 to restore the qmd-first nudge)" >&2
  exit 0
fi
# ${0%/*}, not $(dirname), saves a fork on every call.
case $0 in */*) _py="${0%/*}/qmd-first-nudge.py" ;; *) _py=qmd-first-nudge.py ;; esac
if [ ! -r "$_py" ]; then
  echo "[mh:sensor] internal error: sibling script qmd-first-nudge.py missing or unreadable — allowing (fail-safe = allow)" >&2
  exit 0
fi
python3 -S "$_py" "$@"
exit 0
