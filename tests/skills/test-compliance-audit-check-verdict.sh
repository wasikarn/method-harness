#!/usr/bin/env bash
# skills/review/compliance-audit/scripts/check-verdict.py: validates the
# dispatched verifier's return value and computes `pass` deterministically.
# Run standalone: bash tests/skills/test-compliance-audit-check-verdict.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # used by assert_exit/run_selftest in the sourced lib below
CHECK="$ROOT/skills/review/compliance-audit/scripts/check-verdict.py"
# shellcheck source=../_lib/verdict-assert.sh
source "$ROOT/tests/_lib/verdict-assert.sh"

run_selftest

good='{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "CONFORMS", "note": "", "accepted": null}], "gauntlet": {"command": "bash gauntlet.sh", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'
assert_exit "well-formed all-CONFORMS verdict accepted" 0 "$good"
assert_exit "empty requirements rejected (vacuous-pass guard)" 1 '{"contract_version": 1, "requirements": [], "gauntlet": {"command": "", "sha": "", "exit_code": 0, "output_tail": ""}, "scope_ok": true, "unexpected_files": []}'
assert_exit "extra invented field rejected" 1 '{"contract_version": 1, "requirements": [], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": [], "notes": "x"}'
assert_exit "DEVIATED with accepted null rejected" 1 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "DEVIATED", "note": "n", "accepted": null}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'
assert_exit "NEEDS-DECISION escalation, not malformed" 2 "Can't tell safely.
NEEDS-DECISION does the pinned SHA still check out?"

decoy='{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "MISSING", "note": "", "accepted": null}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 1, "output_tail": "ok"}, "scope_ok": false, "unexpected_files": []}'
assert_exit "decoy verdict ahead of the real one rejected as ambiguous" 1 "Example: $decoy
Actual: $good"

# M3 (harness gap-audit, 2026-09-20): a sanctioned DEVIATED needs a real citation in its note.
assert_exit "DEVIATED+accepted with a citation-shaped note accepted" 0 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "DEVIATED", "note": "see `git diff HEAD~1`", "accepted": true}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'
assert_exit "DEVIATED+accepted with a bare-prose note rejected" 1 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "DEVIATED", "note": "looked fine to me", "accepted": true}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'

# M4: UNVERIFIABLE is a real verdict, never passes on its own.
assert_exit "UNVERIFIABLE accepted as a valid (non-passing) verdict" 0 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "UNVERIFIABLE", "note": "", "accepted": null}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'
assert_exit "UNVERIFIABLE with a stray accepted bool rejected" 1 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "UNVERIFIABLE", "note": "", "accepted": true}], "gauntlet": {"command": "c", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'

# M5: gauntlet.sha must be a real commit-SHA shape; command/output_tail must not be blank.
assert_exit "non-hex gauntlet.sha rejected" 1 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "CONFORMS", "note": "", "accepted": null}], "gauntlet": {"command": "c", "sha": "not-a-sha", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'
assert_exit "blank gauntlet.command rejected" 1 '{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "CONFORMS", "note": "", "accepted": null}], "gauntlet": {"command": "   ", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": []}'

# M5: the orchestrating skill's pinned SHA (passed as an explicit CLI arg) is
# the source of truth -- a mismatching gauntlet.sha is rejected even on an
# otherwise schema-valid object.
mismatch_out=$(printf '%s' "$good" | python3 "$CHECK" deadbeef0 2>&1 >/dev/null)
mismatch_rc=$?
if [ "$mismatch_rc" -eq 1 ] && /usr/bin/grep -q "does not match the pinned SHA" <<<"$mismatch_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: pinned-SHA mismatch rejected — expected exit 1 with a pinned-SHA message, got $mismatch_rc: $mismatch_out"
fi

match_out=$(printf '%s' "$good" | python3 "$CHECK" abc1234)
match_rc=$?
if [ "$match_rc" -eq 0 ] && /usr/bin/grep -q '"pass": true' <<<"$match_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: pinned-SHA match accepted — expected exit 0 with pass:true, got $match_rc: $match_out"
fi

# 2026-09-21 deep-audit: a 40-char pin vs the report's 7-char SHA is the same
# commit -- prefix match, not a false rejection. A <7-char pin is rejected.
full_sha="abc1234000000000000000000000000000000000"
prefix_out=$(printf '%s' "$good" | python3 "$CHECK" "$full_sha")
prefix_rc=$?
if [ "$prefix_rc" -eq 0 ] && /usr/bin/grep -q '"pass": true' <<<"$prefix_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: 40-char pin vs 7-char report accepted — expected exit 0 with pass:true, got $prefix_rc: $prefix_out"
fi
short_out=$(printf '%s' "$good" | python3 "$CHECK" abc 2>&1 >/dev/null)
short_rc=$?
if [ "$short_rc" -eq 1 ] && /usr/bin/grep -q "pinned SHA" <<<"$short_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: 3-char pin rejected — expected exit 1 with a pinned-SHA message, got $short_rc: $short_out"
fi

# 2026-09-21 deep-audit: unexpected_files non-empty -> pass:false, even with
# scope_ok:true and every requirement CONFORMS.
stray='{"contract_version": 1, "requirements": [{"id": "R1", "verdict": "CONFORMS", "note": "", "accepted": null}], "gauntlet": {"command": "bash gauntlet.sh", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"}, "scope_ok": true, "unexpected_files": ["stray.py"]}'
stray_out=$(printf '%s' "$stray" | python3 "$CHECK")
stray_rc=$?
if [ "$stray_rc" -eq 0 ] && /usr/bin/grep -q '"pass": false' <<<"$stray_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: unexpected_files non-empty — expected exit 0 with pass:false, got $stray_rc: $stray_out"
fi

report_verdict "test-compliance-audit-check-verdict"
