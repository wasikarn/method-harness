#!/usr/bin/env bash
# test-run-gauntlet-wiring.sh — a test file on disk with no runner ships
# silently broken. hook_test_files() lists the layer's files by glob, so this
# asserts every test-*.sh / test_*.py under tests/ matches one of those globs.
# It runs only that listing function, never a test (running the runner from
# here recurses: a test that runs the gauntlet re-runs itself).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== run-gauntlet wiring self-test ==="
body=$(sed -n '/^hook_test_files()/,/^}/p' "$GAUNTLET")
[ -n "$body" ] || { echo "  FAIL: hook_test_files() not found in run-gauntlet.sh" >&2; exit 1; }
ran=$(cd "$ROOT" && bash -c "
  $body
  hook_test_files")

# Membership is a string match, never `printf "$ran" | grep -q`: under pipefail, grep -q exits on
# its first match while bash's printf is still writing line by line, so printf takes SIGPIPE (141)
# and a listed file reads as missing. That flaked 2 of 4 gauntlet runs (2026-10-23) and is linted
# by tests/scripts/test-pipefail-grep-q-lint.sh.
NL=$'\n'
missing=()
while IFS= read -r f; do
  rel="${f#"$ROOT/"}"
  case "$NL$ran$NL" in *"$NL$rel$NL"*) ;; *) missing+=("$rel") ;; esac
done < <(find "$ROOT/tests" \( -name "test-*.sh" -o -name "test_*.py" \) | sort)

if [ "${#missing[@]}" -eq 0 ]; then
  ok "hook_test_files() picks up every test-*.sh / test_*.py under tests/"
else
  bad "hook_test_files() does NOT list: ${missing[*]}"
fi

# GH #448: every tests/<dir> must be run by some layer. A dir counts as run when
# hook_test_files() lists a file in it, or it holds mod tests (*.test.ts/tsx) and a
# listed file calls `claude plugin test` (tests/hooks/test-cost-ledger-module.sh).
# tests/_lib holds sourced helpers, not tests.
plugin_test_runner=$(cd "$ROOT" && printf '%s\n' "$ran" | xargs /usr/bin/grep -lE '^[[:space:]]*claude plugin test ' | head -1)
unrun=()
for d in "$ROOT"/tests/*/; do
  name=$(basename "$d")
  [ "$name" = _lib ] && continue
  case "$NL$ran" in *"${NL}tests/$name/"*) continue ;; esac
  if [ -n "$plugin_test_runner" ] && [ -n "$(find "$d" \( -name '*.test.ts' -o -name '*.test.tsx' \) | head -1)" ]; then
    continue
  fi
  unrun+=("tests/$name")
done
if [ "${#unrun[@]}" -eq 0 ]; then
  ok "every tests/<dir> is run by a gauntlet layer (mod tests via ${plugin_test_runner:-none})"
else
  bad "no gauntlet layer runs: ${unrun[*]}"
fi
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
