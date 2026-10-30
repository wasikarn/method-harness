#!/usr/bin/env bash
# Issue #412: idea-audit's Phase 4 memory write must resolve the memory store
# through scripts/_lib/memory-dir.py, not by hand from the live cwd (a linked
# worktree's cwd slug names a store that does not exist, so the write was
# skipped silently). Doc check on the SKILL text plus a script-level check that
# the resolver maps a linked worktree to the main checkout's store.
# Run standalone: bash tests/skills/test-idea-audit-memory-dir.sh
set -uo pipefail
# A pre-push hook env has GIT_DIR set and would hijack the sandbox git init/worktree below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
SKILL="$ROOT/skills/workflow/idea-audit/SKILL.md"
RESOLVER="$ROOT/scripts/_lib/memory-dir.py"
fail=0
ok() { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# 1. Doc check: the step calls the shared resolver, and no longer derives by hand.
if /usr/bin/grep -q 'scripts/_lib/memory-dir.py' "$SKILL"; then
  ok "SKILL calls scripts/_lib/memory-dir.py"
else
  bad "SKILL does not call scripts/_lib/memory-dir.py"
fi
if /usr/bin/grep -q 'the way `skills/meta/learn/scripts/find-transcript.sh` derives' "$SKILL"; then
  bad "SKILL still derives the memory dir by hand like find-transcript.sh"
else
  ok "SKILL has no hand derivation"
fi

# 2. Script check: a linked worktree resolves to the main checkout's store.
TMP="$(mktemp -d)"
trap 'tmp_delete "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
git init -q "$TMP/main"
git -C "$TMP/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP/main" worktree add -q "$TMP/wt" -b wt
main_dir=$(cd "$TMP/main" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PROJECT_DIR_NAME HOME="$TMP/home" python3 "$RESOLVER")
wt_dir=$(cd "$TMP/wt" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PROJECT_DIR_NAME HOME="$TMP/home" python3 "$RESOLVER")
if [ -n "$main_dir" ] && [ "$main_dir" = "$wt_dir" ]; then
  ok "linked worktree resolves to the main checkout's store"
else
  bad "worktree store '$wt_dir' != main store '$main_dir'"
fi

[ "$fail" -eq 0 ] && echo "test-idea-audit-memory-dir: PASS" || echo "test-idea-audit-memory-dir: FAIL"
exit "$fail"
