#!/usr/bin/env bash
# test-run-gauntlet-wiring.sh — a test file on disk with no runner ships
# silently broken. hook_test_files() lists the layer's files by glob, so this
# asserts every test-*.sh / test_*.py under tests/ matches one of those globs.
# It runs only that listing function and start_order(), never a test (running the
# runner from here recurses: a test that runs the gauntlet re-runs itself).
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

# start_order() puts the files that run far longer than their size says first, then the rest by size
# (`ls -S`), so the slowest file does not start ~2 min in and set the gauntlet's end. Run on real files,
# since ls -S reads their sizes.
order_body=$(sed -n '/^start_order()/,/^}/p' "$GAUNTLET")
if [ -z "$order_body" ]; then
  bad "start_order() not found in run-gauntlet.sh"
else
  slow=$(sed -n 's/^  local slow="\(.*\)"$/\1/p' <<<"$order_body")
  read -ra slow_list <<<"$slow"
  small=tests/scripts/test-run-gauntlet-wiring.sh big=tests/hooks/test-gates.sh
  got=$(cd "$ROOT" && printf '%s\n' "$small" "${slow_list[@]}" "$big" | bash -c "$order_body
    start_order")
  want=$(printf '%s\n' "${slow_list[@]}" "$big" "$small")
  if [ -n "$slow" ] && [ "$got" = "$want" ]; then ok "start_order() starts the slow list first, then the rest by size"
  else bad "start_order(): slow='$slow' got: $(tr '\n' ' ' <<<"$got") want: $(tr '\n' ' ' <<<"$want")"; fi
  got=$(cd "$ROOT" && printf '%s\n' "$big" "$small" | bash -c "$order_body
    start_order")
  if [ "$got" = "$(printf '%s\n' "$big" "$small")" ]; then ok "start_order() adds no slow-list file the run did not ask for"
  else bad "start_order() without the slow files: $(tr '\n' ' ' <<<"$got")"; fi
  # A renamed or deleted slow file would drop out of the list silently.
  gone=""
  for f in "${slow_list[@]}"; do case "$NL$ran$NL" in *"$NL$f$NL"*) ;; *) gone="$gone $f" ;; esac; done
  if [ -n "$slow" ] && [ -z "$gone" ]; then ok "every start_order() slow-list file is a listed test file"
  else bad "start_order() slow list names files hook_test_files() does not list:${gone:- (empty list)}"; fi
fi
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
