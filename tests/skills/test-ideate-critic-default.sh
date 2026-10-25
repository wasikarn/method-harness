#!/usr/bin/env bash
# mh:ideate: the critic path (5 Diverge + 1 mh:ideate-critic = 6 Agent calls) is the default for
# every run; host scoring plus Phase 3 (8 calls) is opt-in. A revert of SKILL.md or of the
# ideate-run eval's bounds goes red here.
# Run standalone: bash tests/skills/test-ideate-critic-default.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/skills/workflow/ideate/SKILL.md"
CASE="$ROOT/evals/ideate-run"
fail=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }

check "SKILL.md drops the old host-default rule" \
  "! /usr/bin/grep -qF 'Explicit runs score on' '$SKILL'"
check "SKILL.md names the critic as the default for every run" \
  "/usr/bin/grep -qF 'Every run hands Phase 2 to the' '$SKILL'"
check "SKILL.md keeps the host path as an opt-in" \
  "/usr/bin/grep -qF 'only when the user asks for host scoring' '$SKILL'"
check "fanout.md bounds Agent calls at exactly 6" \
  "/usr/bin/grep -qx 'min: 6' '$CASE/graders/fanout.md' && /usr/bin/grep -qx 'max: 6' '$CASE/graders/fanout.md'"
check "a grader requires the mh:ideate-critic dispatch" \
  "[ -n \"\$(/usr/bin/grep -lx 'tool: Agent' '$CASE'/graders/*.md | xargs /usr/bin/grep -l 'input_match:.*ideate-critic')\" ]"
check "ideate-run prompt allows Bash (rank.py)" \
  "/usr/bin/grep -qE '^allowed_tools: \[.*\bBash\b' '$CASE/prompt.md'"

[ "$fail" -eq 0 ] && echo "PASS: test-ideate-critic-default" || { echo "FAIL: test-ideate-critic-default"; exit 1; }
