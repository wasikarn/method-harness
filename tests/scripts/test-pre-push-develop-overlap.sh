#!/usr/bin/env bash
# test-pre-push-develop-overlap.sh — git-hooks/pre-push refuses to create a branch that changes a file
# origin/develop changed since the branch point, so a duplicate of work already merged shows before the
# PR opens (84c57d69 had fixed the memerr race while the first branch for #613 made the same fix).
# Runs the real hook against a fixture clone of a bare origin, with a stub gauntlet.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo (GH #234).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
HOOK="$ROOT/git-hooks/pre-push"
pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then pass=$((pass + 1)); echo "  PASS: $1"; else fail=$((fail + 1)); echo "  FAIL: $1" >&2; fi; }

echo "=== pre-push: refuse a new branch that overlaps origin/develop ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/pre-push-overlap.XXXXXX") || exit 1
track_trash "$FIXTURE"
export GAUNTLET_LOCK_DIR="$FIXTURE/gauntlet.lock"
# The overlap check runs before either layer; the full path's stub gauntlet marks "allowed" (the fixture's
# manifests are not JSON, so the fast lint would refuse them). One case below runs the fast layer.
export MH_PREPUSH_FULL=1
BARE="$FIXTURE/origin.git" CLONE="$FIXTURE/clone"
ZERO=0000000000000000000000000000000000000000
g() { git -C "$CLONE" -c user.name=t -c user.email=t@example.com "$@"; }
edit() { printf '%s\n' "$2" >> "$CLONE/$1"; g add -- "$1" && g commit -q -m "$3"; }

git init -q --bare "$BARE"
git init -q -b develop "$CLONE"
mkdir -p "$CLONE/scripts" "$CLONE/.claude-plugin"
printf '#!/usr/bin/env bash\necho "stub gauntlet ran"\necho "lock held: $([ -f "${GAUNTLET_LOCK_DIR:-}/pid" ] && echo yes || echo no)"\n' > "$CLONE/scripts/run-gauntlet.sh"
for f in a.txt b.txt r.txt s.txt "my file.txt" .claude-plugin/plugin.json .claude-plugin/marketplace.json; do echo start > "$CLONE/$f"; done
g add -A && g commit -q -m base
g remote add origin "$BARE" && g push -q origin develop
BASE=$(g rev-parse HEAD)

# develop moves on: a.txt, "my file.txt" and both manifests change after BASE.
edit a.txt dev "dev: fix a"
edit "my file.txt" dev "dev: fix spaced"
edit .claude-plugin/plugin.json dev "dev: bump" && edit .claude-plugin/marketplace.json dev "dev: bump 2"
g mv r.txt r2.txt && g commit -q -m "dev: rename r"
edit s.txt dev "dev: fix s"
g push -q origin develop

# branch <name> <file>...: a branch cut at BASE that changes each <file>; prints its head.
branch() {
  local name=$1; shift
  g checkout -q -b "$name" "$BASE" && for f in "$@"; do edit "$f" "$name" "$name: $f"; done
  g rev-parse HEAD; g checkout -q develop
}
# push_hook <local sha> <remote sha> [remote name]: run the hook as git would for refs/heads/x.
push_hook() {
  printf 'refs/heads/x %s refs/heads/x %s\n' "$1" "$2" | (cd "$CLONE" && bash "$HOOK" "${3:-origin}" "$BARE" 2>&1)
}

head=$(branch dup a.txt)
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -ne 0 ] && [[ $out == *a.txt* && $out == *"dev: fix a"* && $out != *"stub gauntlet ran"* ]] && [ ! -e "$GAUNTLET_LOCK_DIR" ] && ok=0
check "new branch changing a file develop changed since the branch point: refused, names file and commit, no gauntlet, no lock" "$ok"

head=$(branch byurl a.txt)
out=$(push_hook "$head" "$ZERO" "$BARE"); rc=$?
ok=1; [ "$rc" -ne 0 ] && [[ $out == *a.txt* ]] && ok=0
check "push to a URL, not a named remote (git passes the URL as \$1): still refused" "$ok"

head=$(branch spaced "my file.txt")
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -ne 0 ] && [[ $out == *"my file.txt"* && $out == *"dev: fix spaced"* ]] && ok=0
check "a path with a space is matched and named" "$ok"

# git diff detects renames by default and would list only the new name on the renaming side.
head=$(branch editrenamed r.txt)
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -ne 0 ] && [[ $out == *r.txt* && $out == *"dev: rename r"* ]] && ok=0
check "branch edits a file develop renamed: refused" "$ok"

g checkout -q -b renames "$BASE" && g mv s.txt s2.txt && g commit -q -m "renames: s"
head=$(g rev-parse HEAD); g checkout -q develop
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -ne 0 ] && [[ $out == *s.txt* && $out == *"dev: fix s"* ]] && ok=0
check "branch renames a file develop edited: refused" "$ok"

head=$(branch clean b.txt)
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"stub gauntlet ran"* ]] && ok=0
check "new branch with no overlap: allowed, gauntlet runs" "$ok"

# GH #735 fast layer: lint only what the branch changed since develop (b.txt), not the fixture's invalid
# JSON manifests, which a whole-tree lint would refuse.
out=$(MH_PREPUSH_FULL='' push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"linting 1 changed file(s)"* && $out != *"stub gauntlet ran"* ]] && ok=0
check "fast layer on a new branch: lints the one file it changed since develop, no gauntlet" "$ok"

head=$(branch bump .claude-plugin/plugin.json .claude-plugin/marketplace.json b.txt)
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"stub gauntlet ran"* ]] && ok=0
check "overlap on the two manifests only: allowed (every PR bumps them)" "$ok"

g checkout -q -b synced "$BASE" && edit a.txt synced "synced: a" && g merge -q --no-edit develop >/dev/null 2>&1
g add -- a.txt >/dev/null 2>&1; g commit -q --no-edit >/dev/null 2>&1
head=$(g rev-parse HEAD); g checkout -q develop
out=$(push_hook "$head" "$ZERO"); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"stub gauntlet ran"* ]] && ok=0
check "new branch that has merged develop: allowed" "$ok"

head=$(branch existing a.txt)
out=$(push_hook "$head" "$BASE"); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"stub gauntlet ran"* ]] && ok=0
check "push to an existing branch: not checked (sync-pr-head pushes there; develop moves every few minutes)" "$ok"

out=$(printf '(delete) %s refs/heads/x %s\n' "$ZERO" "$BASE" | (cd "$CLONE" && bash "$HOOK" origin "$BARE" 2>&1)); rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "branch delete: not checked" "$ok"

head=$(branch tagged a.txt)
out=$(printf 'refs/tags/v1 %s refs/tags/v1 %s\n' "$head" "$ZERO" | (cd "$CLONE" && bash "$HOOK" origin "$BARE" 2>&1)); rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "tag push: not checked" "$ok"

head=$(branch nofetch a.txt)
out=$(push_hook "$head" "$ZERO" nosuchremote); rc=$?
ok=1; [ "$rc" -eq 0 ] && [[ $out == *"skipping the develop-overlap check"* && $out == *"stub gauntlet ran"* ]] && ok=0
check "develop cannot be fetched: a diagnostic, then allowed" "$ok"

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
