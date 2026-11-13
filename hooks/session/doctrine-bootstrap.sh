#!/usr/bin/env bash
# SessionStart: inject docs/METHODOLOGY.md whole into the session context.
# Output goes to stdout → CC injects it as system context for the session.
set -uo pipefail

METHODOLOGY="${CLAUDE_PLUGIN_ROOT:-}/docs/METHODOLOGY.md"

if [[ -f "$METHODOLOGY" && -s "$METHODOLOGY" && -r "$METHODOLOGY" ]]; then
  echo "<doctrine>"
  cat "$METHODOLOGY"
  echo "</doctrine>"
else
  # A partial or corrupt plugin cache, an empty or unreadable file, or an unset root: say so, or the session starts with no doctrine and no sign.
  echo "<!-- mh:doctrine-missing -->"
  echo "**method-harness:** ${METHODOLOGY} is missing, empty or unreadable, so this session has no doctrine. Reinstall mh@wasikarn or check CLAUDE_PLUGIN_ROOT."
  echo "<!-- /mh:doctrine-missing -->"
fi

# Dependency preflight (#93): the deny gates fail OPEN (with a per-call stderr
# note) when python3 is missing — announce that once, up front, so the
# degradation is visible at session start instead of being discovered
# mid-destructive-command. jq gates the cost tracker the same way (it skips
# itself silently per-event; this is its one announcement).
if ! command -v python3 >/dev/null 2>&1; then
  # Gate list derived from hooks/gates/*.sh (LOW, harness gap-audit
  # 2026-09-20) instead of a hand-maintained string -- the previous
  # hardcoded list named 5 of the 7 real gate wrappers, silently missing
  # subagent-spawn-guard and others whenever a new gate shipped.
  _gate_list=""
  for _g in "${CLAUDE_PLUGIN_ROOT:-}"/hooks/gates/*.sh; do
    [ -f "$_g" ] || continue
    _name=$(basename "$_g" .sh)
    _gate_list="${_gate_list:+$_gate_list / }$_name"
  done
  echo "<!-- mh:portability-preflight -->"
  echo "**method-harness:** \`python3\` not found on PATH. Every gate (${_gate_list:-every hooks/gates/*.sh wrapper}) is failing open with a stderr note — destructive-command protection is OFF until python3 is installed."
  echo "<!-- /mh:portability-preflight -->"
  unset _gate_list _g _name
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "<!-- mh:portability-preflight -->"
  echo "**method-harness:** \`jq\` not found on PATH. Cost tracking (hooks/stop/cost-tracker.sh) will skip itself this session."
  echo "<!-- /mh:portability-preflight -->"
fi
# node runs the report side only (skills/meta/cost-report/scripts/cost-report-dedup.js behind
# /mh:cost-report); the tracker keeps writing rows without it.
if ! command -v node >/dev/null 2>&1; then
  echo "<!-- mh:portability-preflight -->"
  echo "**method-harness:** \`node\` not found on PATH. \`/mh:cost-report\` cannot render the metrics log until node is installed; cost rows are still being written."
  echo "<!-- /mh:portability-preflight -->"
fi

exit 0
