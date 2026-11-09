#!/usr/bin/env bash
# deep-audit step 3 runs scripts/_lib/citation_exists.py over the checker's accepted verdict, report-only.
# Run standalone: bash tests/skills/test-deep-audit-citation-wiring.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/review/deep-audit/SKILL.md"
fail=0
bad() { echo "FAIL: $1" >&2; fail=1; }
ok() { echo "  PASS: $1"; }

text="$(<"$SKILL")"
has() { [[ "$text" == *"$1"* ]]; }

# The command the skill tells the model to run must be a real script, reached the way weighted-score is.
has 'scripts/_lib/citation_exists.py' && ok "SKILL.md names citation_exists.py" || bad "SKILL.md does not name scripts/_lib/citation_exists.py"
[ -f "$ROOT/skills/review/deep-audit/../../../scripts/_lib/citation_exists.py" ] && ok "the script path resolves from the skill dir" || bad "scripts/_lib/citation_exists.py is not reachable from the skill dir"
has '--diff-paths' && ok "SKILL.md passes --diff-paths (a file the diff deleted still counts)" || bad "SKILL.md does not pass --diff-paths"
has 'git diff --name-only' && ok "the diff list comes from git diff --name-only" || bad "SKILL.md does not say how to build the --diff-paths list"

# Report-only: it never decides pass/fail and never drops a finding.
has 'report-only' && ok "SKILL.md says report-only" || bad "SKILL.md does not say report-only"
has 'never changes `pass`' && ok "SKILL.md says it never changes pass" || bad "SKILL.md does not say it never changes pass"
has 'never drops a finding' && ok "SKILL.md says it never drops a finding" || bad "SKILL.md does not say it never drops a finding"
has 'not proof of fabrication' && ok "SKILL.md says missing is not proof of fabrication" || bad "SKILL.md does not say missing is not proof of fabrication"

# The wording contract of the checker: "citations exist", never "verified".
has 'citations exist' && ok "SKILL.md reports 'citations exist'" || bad "SKILL.md does not use the words 'citations exist'"

# It runs after the verdict is accepted, so before findings are reconciled.
before="${text%%citation_exists.py*}"
[[ "$before" == *'check-verdict.py'* ]] && [[ "$before" != *'Reconcile its findings'* ]] && ok "it comes after check-verdict and before reconcile" || bad "citation step is not between check-verdict and Reconcile its findings"

echo "=== $([ $fail -eq 0 ] && echo OK || echo FAILED) ==="
exit $fail
