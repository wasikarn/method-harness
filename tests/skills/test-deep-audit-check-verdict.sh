#!/usr/bin/env bash
# skills/review/deep-audit/scripts/check-verdict.py: validates the Claude-
# fallback checker's return value from presence-only to full shape/type
# validity, and distinguishes a valid NEEDS-DECISION escalation from a
# rejected/malformed verdict.
# Run standalone: bash tests/skills/test-deep-audit-check-verdict.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # used by assert_exit/run_selftest in the sourced lib below
CHECK="$ROOT/skills/review/deep-audit/scripts/check-verdict.py"
# shellcheck source=../_lib/verdict-assert.sh
source "$ROOT/tests/_lib/verdict-assert.sh"

run_selftest

checked='[{"claim": "c", "evidence": "skills/foo.py:12"}]'
good='{"contract_version": 1, "pass": true, "findings": [], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "well-formed verdict accepted" 0 "$good"
assert_exit "extra invented field rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": '"$checked"', "scope_ok": true, "unexpected_files": [], "notes": "x"}'
assert_exit "pass as string rejected" 1 '{"contract_version": 1, "pass": "mostly", "findings": [], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "scope_ok null rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": '"$checked"', "scope_ok": null, "unexpected_files": []}'
assert_exit "malformed findings item rejected" 1 '{"contract_version": 1, "pass": false, "findings": [{"issue": "x"}], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "empty checked rejected (vacuous-pass guard)" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": [], "scope_ok": true, "unexpected_files": []}'
assert_exit "NEEDS-DECISION escalation, not malformed" 2 "I can't tell safely.
NEEDS-DECISION does gate X apply to Y?"

decoy='{"contract_version": 1, "pass": false, "findings": [], "checked": '"$checked"', "scope_ok": false, "unexpected_files": []}'
real='{"contract_version": 1, "pass": true, "findings": [{"summary": "s", "evidence": "ran `git log -1`"}], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "decoy verdict ahead of the real one rejected as ambiguous" 1 "Example shape: $decoy
Actual result: $real"

assert_exit "hedged verdict ahead of a real escalation does not override it" 2 "If I could conclude, the shape I'd return is $decoy but I can't commit to that without seeing the file.
NEEDS-DECISION does gate X still apply after the file was deleted?"

assert_exit "escalation not misclassified as malformed by unrelated JSON prose" 2 'the config block looks like {"timeout": 30} in one place and {"timeout": 60} in another.
NEEDS-DECISION which config value is the source of truth here?'

# M1 (harness gap-audit, 2026-09-20): pass:true can't override the host's own scope facts.
assert_exit "pass:true over scope_ok:false rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": '"$checked"', "scope_ok": false, "unexpected_files": []}'
assert_exit "pass:true with non-empty unexpected_files rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": '"$checked"', "scope_ok": true, "unexpected_files": ["x.py"]}'
assert_exit "pass:false over scope_ok:false still accepted (a legit failing run)" 0 '{"contract_version": 1, "pass": false, "findings": [], "checked": '"$checked"', "scope_ok": false, "unexpected_files": []}'

# M6: blank summary/evidence/claim strings are schema-valid non-empty-type but carry no content.
assert_exit "blank findings.summary rejected" 1 '{"contract_version": 1, "pass": false, "findings": [{"summary": "  ", "evidence": "e"}], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "blank checked.evidence rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": [{"claim": "c", "evidence": ""}], "scope_ok": true, "unexpected_files": []}'

# #392: evidence must carry the citation shape idea-audit's check-citations.py enforces.
assert_exit "non-citation checked.evidence rejected" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": [{"claim": "c", "evidence": "x"}], "scope_ok": true, "unexpected_files": []}'
assert_exit "non-citation findings.evidence rejected" 1 '{"contract_version": 1, "pass": false, "findings": [{"summary": "s", "evidence": "looks wrong to me"}], "checked": '"$checked"', "scope_ok": true, "unexpected_files": []}'
assert_exit "numeric ratio is not a citation" 1 '{"contract_version": 1, "pass": true, "findings": [], "checked": [{"claim": "c", "evidence": "ratio 2.5:1"}], "scope_ok": true, "unexpected_files": []}'

# #439: the Codex primary path's acceptance paragraph must pipe its output through
# check-verdict.py too, not accept on schema validity alone.
codex_accept=$(awk '/^\*\*Accept the result only if/{on=1} /^\*\*On any other outcome/{on=0} on' \
  "$ROOT/skills/review/deep-audit/SKILL.md")
if /usr/bin/grep -q 'check-verdict\.py' <<<"$codex_accept"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: deep-audit Codex acceptance paragraph does not name check-verdict.py"
fi

report_verdict "test-deep-audit-check-verdict"
