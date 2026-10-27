#!/usr/bin/env bash
# test-git-identity-leak.sh — a test that runs `git config user.*` in its own sandbox repo must not
# write that identity into the real repo when a git hook has exported GIT_DIR (pre-push from a linked
# worktree does). Found 2026-09-29: test-isolated-checkout-dispatch.sh ran under a poisoned GIT_DIR
# left `Test <test@example.com>` in the shared .git/config, so later commits in every worktree were
# authored as Test. run-gauntlet.sh unsets GIT_* for its children, but a test run any other way did not.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
TARGET="$HERE/test-isolated-checkout-dispatch.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== test git-identity leak under a poisoned GIT_DIR ==="

DECOY="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
cleanup() { [ -n "${DECOY:-}" ] && python3 "$HERE/../_lib/tmp_delete.py" "$DECOY"; }
trap cleanup EXIT

( cd "$DECOY" && git init -q -b decoy . ) >/dev/null 2>&1
before="$(git -C "$DECOY" config --local --get-regexp '^user\.' 2>/dev/null || true)"

GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" GIT_INDEX_FILE="$DECOY/.git/index" \
  bash "$TARGET" >/dev/null 2>&1

after="$(git -C "$DECOY" config --local --get-regexp '^user\.' 2>/dev/null || true)"
[ "$before" = "$after" ] \
  && ok "$(basename "$TARGET") leaves the caller's repo config alone under a poisoned GIT_DIR" \
  || bad "$(basename "$TARGET") wrote into the caller's repo config: ${after:-<empty>}"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
