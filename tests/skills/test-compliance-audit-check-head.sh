#!/usr/bin/env bash
# Issue #395: compliance-audit's ship step said "pass true -> ship/merge" with no
# check that the branch head still equals the audited SHA. check-head.sh does
# that compare; the pin paragraph (Phase 1.4) and the ship bullet (Phase 3.4)
# must each name it. Paragraph-scoped on purpose: a whole-file grep passed
# before the fix.
# Run standalone: bash tests/skills/test-compliance-audit-check-head.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/skills/review/compliance-audit/SKILL.md"
CH="$ROOT/skills/review/compliance-audit/scripts/check-head.sh"
# shellcheck source=../_lib/harness.sh
source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
fail=0

R=$(fresh_repo)
[ -n "$R" ] && [ -d "$R/.git" ] || { echo "FAIL: fresh_repo made no repo (mktemp failed?)"; exit 1; }
git -C "$R" commit -q --allow-empty -m one
audited=$(git -C "$R" rev-parse HEAD)

check() { # name expected-exit sha ref
  local out code
  out=$(cd "$R" && bash "$CH" "$3" "$4" 2>&1); code=$?
  if [ "$code" -ne "$2" ]; then echo "FAIL: $1: exit $code, want $2: $out"; fail=1; else echo "ok: $1"; fi
}
check "head equals audited SHA" 0 "$audited" HEAD
check "abbreviated audited SHA matches" 0 "${audited:0:10}" HEAD
git -C "$R" commit -q --allow-empty -m two
check "head moved after audit" 1 "$audited" HEAD
check "unresolvable ref" 2 "$audited" no-such-branch
check "unresolvable audited SHA" 2 deadbeefdeadbeef HEAD
check "missing argument" 2 "$audited" ""
check "a ref as the pin is not a SHA (HEAD HEAD)" 2 HEAD HEAD
check "a branch name as the pin is not a SHA" 2 "$(git -C "$R" branch --show-current)" HEAD

git -C "$R" branch deadbeef
check "a branch named like a hex SHA is not a pin" 2 deadbeef deadbeef
git -C "$R" branch -q -D deadbeef

# Paragraph scope: Phase 1 step 4 (pin) and the Phase 3 "pass true" ship bullet.
pin=$(awk '/^4\. \*\*Pin the revision safely/{p=1} p&&/^5\. /{exit} p' "$SKILL")
ship=$(awk '/^   - `pass` true/{p=1;print;next} p&&/^   - /{exit} p' "$SKILL")
for pair in "pin:$pin" "ship:$ship"; do
  name=${pair%%:*}; body=${pair#*:}
  if [ -z "$body" ]; then echo "FAIL: $name paragraph not found"; fail=1; continue; fi
  if /usr/bin/grep -q 'check-head.sh' <<<"$body"; then
    echo "ok: $name paragraph names check-head.sh"
  else
    echo "FAIL: $name paragraph does not name check-head.sh"; fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
