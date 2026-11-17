#!/usr/bin/env bash
# test-gauntlet-claude-env-isolation.sh — regression test: run-gauntlet.sh must clear CLAUDE_CONFIG_DIR
# before the test layer launches. A Claude Code session exports it (a profile dir), and five hook tests
# (config-write-guard, memory-audit-commit, memory-health-nudge, session-stop, skill-usage-telemetry)
# then read that profile instead of their fixture HOME and fail; so did merge-pr.sh's gauntlet (2026-11-17).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet CLAUDE_CONFIG_DIR isolation ==="

UNSET_LINE=$(/usr/bin/grep -E '^unset CLAUDE_CONFIG_DIR' "$GAUNTLET" || true)
if [ -z "$UNSET_LINE" ]; then
  bad "run-gauntlet.sh has no 'unset CLAUDE_CONFIG_DIR' line"
else
  unset_line_no=$(/usr/bin/grep -n '^unset CLAUDE_CONFIG_DIR' "$GAUNTLET" | head -1 | cut -d: -f1)
  invoke_line_no=$(/usr/bin/grep -n 'run_hook_tests >"\$LOG/tests"' "$GAUNTLET" | head -1 | cut -d: -f1)
  if [ -n "$invoke_line_no" ] && [ "$unset_line_no" -lt "$invoke_line_no" ]; then
    ok "CLAUDE_CONFIG_DIR unset happens before run_hook_tests is launched"
  else
    bad "CLAUDE_CONFIG_DIR unset is after run_hook_tests launches (or the launch line was not found)"
  fi

  result=$(
    export CLAUDE_CONFIG_DIR=/nonexistent/profile
    eval "$UNSET_LINE"
    declare -p CLAUDE_CONFIG_DIR >/dev/null 2>&1 && echo "STILL-SET" || echo OK
  )
  if [ "$result" = "OK" ]; then
    ok "the extracted unset statement clears a poisoned CLAUDE_CONFIG_DIR"
  else
    bad "the extracted unset statement left CLAUDE_CONFIG_DIR set"
  fi
fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
