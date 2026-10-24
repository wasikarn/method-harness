#!/usr/bin/env bash
# skills/review/deep-audit/scripts/scope-fingerprint.py: snapshot records
# existence + content hash per scope path; compare flags a changed hash, a
# path that appeared, and a path that disappeared (issue #414).
# Run standalone: bash tests/skills/test-deep-audit-scope-fingerprint.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FP="$ROOT/skills/review/deep-audit/scripts/scope-fingerprint.py"
# shellcheck source=../_lib/harness.sh
source "$ROOT/tests/_lib/harness.sh"
T="$(mktemp -d)"
track_trash "$T"
trap _cleanup_trash EXIT
fail=0
check() { # name expected-exit expected-stdout-substring(or empty)
  local name="$1" want="$2" pat="$3" out code
  out=$(python3 "$FP" compare "$T/m.json" 2>&1); code=$?
  if [ "$code" -ne "$want" ]; then echo "FAIL: $name: exit $code, want $want: $out"; fail=1; return; fi
  if [ -n "$pat" ] && ! /usr/bin/grep -qF -- "$pat" <<<"$out"; then
    echo "FAIL: $name: missing '$pat' in: $out"; fail=1; return
  fi
  echo "ok: $name"
}
snap() { printf '%s\n' "$T/a" "$T/b" "$T/gone" "$T/d" | python3 "$FP" snapshot "$T/m.json" || { echo "FAIL: snapshot exit $?"; fail=1; }; }

reset() { printf 'one' >"$T/a"; printf 'two' >"$T/b"; mkdir -p "$T/d"; printf 'x' >"$T/d/f"; rm -f "$T/gone"; }

reset; snap
check "unchanged scope is stable" 0 ""

printf 'ONE' >"$T/a"
check "changed hash flagged" 1 "changed: $T/a"

reset; snap; printf 'new' >"$T/gone"
check "appeared path flagged" 1 "appeared: $T/gone"

reset; snap; rm -f "$T/b"
check "disappeared path flagged" 1 "disappeared: $T/b"

reset; snap; printf 'y' >"$T/d/f"
check "changed file inside a scoped directory flagged" 1 "changed: $T/d"

reset; snap; touch "$T/a"
check "mtime-only touch is not a change" 0 ""

out=$(printf '' | python3 "$FP" snapshot "$T/empty.json" 2>&1); code=$?
[ "$code" -eq 2 ] && [ -n "$out" ] && echo "ok: snapshot of no paths is a usage error (2)" || { echo "FAIL: snapshot of no paths exit $code: $out"; fail=1; }

out=$(python3 "$FP" compare "$T/nope.json" 2>&1); code=$?
[ "$code" -eq 2 ] && echo "ok: missing manifest is a usage error (2)" || { echo "FAIL: missing manifest exit $code: $out"; fail=1; }

printf '{}' >"$T/emptym.json"
out=$(python3 "$FP" compare "$T/emptym.json" 2>&1); code=$?
[ "$code" -eq 2 ] && echo "ok: an empty manifest is a usage error (2), not a vacuous pass" || { echo "FAIL: empty manifest exit $code: $out"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: test-deep-audit-scope-fingerprint" || { echo "FAIL: test-deep-audit-scope-fingerprint"; exit 1; }
