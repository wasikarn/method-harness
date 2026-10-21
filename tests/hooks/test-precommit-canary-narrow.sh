#!/usr/bin/env bash
# Pins the pre-commit canary narrowing: which staged hooks/gates files canary one gate vs all.
# Extracts the loop from git-hooks/pre-commit and evals it against a fake index.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
idx="$(mktemp -d)"
trap 'trash "$idx" 2>/dev/null' EXIT
mkdir -p "$idx/hooks/gates"
touch "$idx/hooks/gates/irrecoverable.sh" "$idx/hooks/gates/secret-scan.sh" "$idx/hooks/gates/_silent_fastpath.sh"
body=$(sed -n '/^  only=()/,/^  done <<</p' "$ROOT/git-hooks/pre-commit")
[ -n "$body" ] || { echo "FAIL: narrowing loop not found in git-hooks/pre-commit"; exit 1; }

fail=0
t() { # expected, staged files...
  local want="$1"; shift
  local gates_staged only
  # shellcheck disable=SC2034 # read by the eval'd loop body
  gates_staged=$(printf '%s\n' "$@")
  eval "$body"
  local got="${only[*]-}"; [ -n "$got" ] || got=ALL
  if [ "$got" = "$want" ]; then echo "PASS: [$*] -> $got"; else echo "FAIL: [$*] -> $got (want $want)"; fail=1; fi
}

t irrecoverable.sh hooks/gates/irrecoverable.sh
t irrecoverable.sh hooks/gates/irrecoverable.py
t "irrecoverable.sh secret-scan.sh" hooks/gates/irrecoverable.py hooks/gates/secret-scan.sh
t ALL hooks/gates/_journal.py
t ALL hooks/gates/_silent_fastpath.sh
t ALL hooks/gates/secret-scan.sh hooks/gates/_silent_fastpath.sh
t ALL hooks/gates/brace-route.awk
t ALL hooks/gates/new-gate.sh
t ALL hooks/gates/sub/x.sh

[ "$fail" -eq 0 ] && echo "precommit-canary-narrow: all passed" || { echo "precommit-canary-narrow: FAILED"; exit 1; }
