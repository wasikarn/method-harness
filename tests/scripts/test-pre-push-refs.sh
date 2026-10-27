#!/usr/bin/env bash
# test-pre-push-refs.sh — git-hooks/pre-push's stdin ref-line gate (Phase B,
# 2026-09-28): refuse a direct push whose remote_ref is refs/heads/develop,
# before anything else runs. Then the layer an allowed push gets (GH #735): by
# default a fast lint of the files the push changes, read from the pushed
# commit, with no gauntlet and no gauntlet lock; with MH_PREPUSH_FULL=1 the
# full gauntlet under the lock. Runs the real hook script against a throwaway
# fixture repo (own scripts/run-gauntlet.sh stub) so this test never pays for
# the real gauntlet or touches the real repo's own git state.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
unset MH_PREPUSH_FULL
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
HOOK="$ROOT/git-hooks/pre-push"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
assert_pass() { [ "$1" -eq 1 ] && ok "$2" || bad "$2"; }

echo "=== pre-push: refuse a direct push to refs/heads/develop; fast lint by default ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
# A missing TMPDIR makes mktemp print "" and `trash ""` trashes the cwd: stop, and let
# _cleanup_trash (which drops empties) do the trashing.
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/pre-push-fixture.XXXXXX") || exit 1
track_trash "$FIXTURE"
g() { git -C "$FIXTURE" -c user.name=t -c user.email=t@example.com "$@"; }

g init -q .
mkdir -p "$FIXTURE/scripts"
cat > "$FIXTURE/scripts/run-gauntlet.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub gauntlet ran"
echo "lock held: $([ -f "${GAUNTLET_LOCK_DIR:-}/pid" ] && echo yes || echo no)"
exit 0
EOF
chmod +x "$FIXTURE/scripts/run-gauntlet.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE/good.sh"
g add -A && g commit -q -m base
BASE=$(g rev-parse HEAD)
# GH #158: the full path queues behind other gauntlets; keep this test's lock out of the real one.
export GAUNTLET_LOCK_DIR="$FIXTURE/gauntlet.lock"

run_hook() {
  # stdin from $1 (a file), cwd the fixture repo so `git rev-parse
  # --show-toplevel` inside the real hook resolves to the fixture, not this
  # repo.
  ( cd "$FIXTURE" && bash "$HOOK" < "$1" )
}
in=$(mktemp); track_trash "$in"
# ref_line <local ref> <local sha> <remote ref> <remote sha>: write the hook's stdin.
ref_line() { printf '%s %s %s %s\n' "$@" > "$in"; }

LOCAL_SHA="1111111111111111111111111111111111111111"
ZERO="0000000000000000000000000000000000000000"

# --- direct push to develop: refused, nothing runs ---
ref_line refs/heads/feat/x "$LOCAL_SHA" refs/heads/develop "$ZERO"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* && "$out" != *"stub gauntlet ran"* && "$out" != *"linting"* ]] && o=1 || o=0
assert_pass "$o" "push to refs/heads/develop is refused, no lint or gauntlet runs"

# --- delete of develop (all-zero local_sha): still refused ---
ref_line '(delete)' "$ZERO" refs/heads/develop "$LOCAL_SHA"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* ]] && o=1 || o=0
assert_pass "$o" "deleting refs/heads/develop is also refused (any local_sha, including the delete sentinel)"

# --- multi-ref push, only one line targets develop: refused overall ---
{
  printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' "$BASE" "$ZERO"
  printf 'refs/heads/y %s refs/heads/develop %s\n' "$BASE" "$ZERO"
} > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* ]] && o=1 || o=0
assert_pass "$o" "a multi-ref push where only one line targets develop is refused"

# --- allowed pushes: a tag, a feat/* and a fix/* branch get the fast lint, no gauntlet, no lock ---
for r in refs/tags/v1 refs/heads/feat/x refs/heads/fix/y; do
  ref_line "$r" "$BASE" "$r" "$ZERO"
  out=$(run_hook "$in" 2>&1); rc=$?
  [[ "$rc" -eq 0 && "$out" == *"linting"* && "$out" != *"stub gauntlet ran"* && ! -e "$GAUNTLET_LOCK_DIR" ]] && o=1 || o=0
  assert_pass "$o" "a push to $r is allowed: fast lint, no gauntlet, no gauntlet lock"
done

# --- genuinely empty stdin: allowed ---
: > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" != *"stub gauntlet ran"* ]] && o=1 || o=0
assert_pass "$o" "empty stdin (nothing to push) is allowed"

# --- a malformed non-empty line: fails closed, with a diagnostic ---
printf 'only-two-fields %s\n' "$LOCAL_SHA" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"malformed"* && "$out" != *"stub gauntlet ran"* ]] && o=1 || o=0
assert_pass "$o" "a malformed ref line fails closed with a diagnostic, never a silent pass-through"

# --- a pushed sha this repo does not have: fails closed, never skips the lint ---
ref_line refs/heads/feat/x "$LOCAL_SHA" refs/heads/feat/x "$ZERO"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"not an object"* ]] && o=1 || o=0
assert_pass "$o" "an unknown pushed sha is refused, not skipped"

# --- the fast lint catches a bad shell file, a bad JSON file and a home path in the pushed commit ---
printf 'echo "unterminated\n' > "$FIXTURE/bad.sh"
g add bad.sh && g commit -q -m bad-sh
BAD=$(g rev-parse HEAD)
ref_line refs/heads/feat/x "$BAD" refs/heads/feat/x "$BASE"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"lint failed"* && "$out" == *"linting 1 changed file(s)"* ]] && o=1 || o=0
assert_pass "$o" "a shell syntax error in the pushed range fails the push"
# Only the range is linted: bad.sh was already on the remote's old sha, the push adds good2.sh.
printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE/good2.sh"
g add good2.sh && g commit -q -m good2
GOOD2=$(g rev-parse HEAD)
ref_line refs/heads/feat/x "$GOOD2" refs/heads/feat/x "$BAD"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"linting 1 changed file(s)"* ]] && o=1 || o=0
assert_pass "$o" "a file outside the pushed range is not linted (lints the diff from the remote's old sha)"
# With no base (a new ref, no develop to diff against), every file in the commit is linted.
ref_line refs/heads/feat/x "$GOOD2" refs/heads/feat/x "$ZERO"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"lint failed"* ]] && o=1 || o=0
assert_pass "$o" "with no base to diff against, the whole commit is linted"
printf '{"a": \n' > "$FIXTURE/bad.json"
g add bad.json && g commit -q -m bad-json
ref_line refs/heads/feat/x "$(g rev-parse HEAD)" refs/heads/feat/x "$GOOD2"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"invalid JSON"* ]] && o=1 || o=0
assert_pass "$o" "invalid JSON in the pushed range fails the push"
g rm -q bad.json && g commit -q -m drop-json
# The pattern is split so this file does not trip the ban itself.
printf 'see /%s/someone/x\n' "Users" > "$FIXTURE/notes.txt"
g add notes.txt && g commit -q -m home
ref_line refs/heads/feat/x "$(g rev-parse HEAD)" refs/heads/feat/x "$GOOD2"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"hardcoded home path"* ]] && o=1 || o=0
assert_pass "$o" "a home path in the pushed range fails the push"
g rm -q notes.txt && g commit -q -m drop-home
# The commit is linted, not the working tree: a dirty bad edit beside a clean pushed commit passes.
CLEAN=$(g rev-parse HEAD)
printf 'echo "unterminated\n' > "$FIXTURE/good2.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE/good3.sh"
g add good3.sh && g commit -q -m good3
ref_line refs/heads/feat/x "$(g rev-parse HEAD)" refs/heads/feat/x "$CLEAN"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && o=1 || o=0
assert_pass "$o" "the lint reads the pushed commit, not the dirty working tree"
g checkout -q -- good2.sh

# --- MH_PREPUSH_FULL=1: the full gauntlet runs while the hook holds the machine-wide lock (GH #158),
# and the lock is released afterwards, on success and on a failing gauntlet ---
ref_line refs/heads/feat/x "$BASE" refs/heads/feat/x "$ZERO"
out=$(MH_PREPUSH_FULL=1 run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"lock held: yes"* && "$out" != *"linting"* && ! -e "$GAUNTLET_LOCK_DIR" ]] && o=1 || o=0
assert_pass "$o" "MH_PREPUSH_FULL=1 runs the gauntlet under the lock, and the lock is gone after a passing run"
printf '#!/usr/bin/env bash\necho "stub gauntlet failed"\nexit 3\n' > "$FIXTURE/scripts/run-gauntlet.sh"
out=$(MH_PREPUSH_FULL=1 run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 3 && ! -e "$GAUNTLET_LOCK_DIR" ]] && o=1 || o=0
assert_pass "$o" "a failing full gauntlet keeps its exit status and still releases the lock"

# --- a refused push never touches the lock ---
ref_line refs/heads/feat/x "$LOCAL_SHA" refs/heads/develop "$ZERO"
out=$(MH_PREPUSH_FULL=1 run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && ! -e "$GAUNTLET_LOCK_DIR" ]] && o=1 || o=0
assert_pass "$o" "a push refused before the gauntlet never takes the lock"

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
