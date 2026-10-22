#!/usr/bin/env bash
# Sensor: after a Bash or MCP tool call, replace vendor-specific credential-shaped tokens in
# Bash stdout/stderr or MCP text blocks with a [REDACTED:<kind>] marker before the model sees them
# (PostToolUse hookSpecificOutput.updatedToolOutput; probed 2026-10-22 on CC
# 2.1.307, GH #534). Bash and MCP text blocks; Read output was not rewritable in the same probe.
# Best-effort, not a guarantee: it reuses secret-scan.py's vendor-prefix
# PATTERNS, so a secret outside those shapes passes through.
#
# Never denies or blocks. Fails OPEN: a crash, bad JSON or a missing sibling
# leaves the original output visible (probed: exit 1, invalid JSON and exit 2
# all left it untouched). Prints nothing unless it redacted something.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:sensor] python3 not found -- bash-output-redact cannot run; output left unredacted" >&2
  exit 0
fi

_py="$(dirname "$0")/bash-output-redact.py"
if [ ! -r "$_py" ]; then
  echo "[mh:sensor] internal error: sibling script bash-output-redact.py missing or unreadable -- output left unredacted" >&2
  exit 0
fi

python3 -S "$_py"
exit 0
