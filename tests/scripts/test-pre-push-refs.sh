#!/usr/bin/env bash
# test-pre-push-refs.sh — git-hooks/pre-push's stdin ref-line gate (Phase B,
# 2026-09-28): refuse a direct push whose remote_ref is refs/heads/develop,
# before the gauntlet runs. Runs the real hook script against a throwaway
# fixture repo (own scripts/run-gauntlet.sh stub) so a passing case doesn't
# have to pay for the real gauntlet, and so this test never touches the real
# repo's own git state.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
HOOK="$ROOT/git-hooks/pre-push"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== pre-push: refuse a direct push to refs/heads/develop ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
# A missing TMPDIR makes mktemp print "" and `trash ""` trashes the cwd: stop, and let
# _cleanup_trash (which drops empties) do the trashing.
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/pre-push-fixture.XXXXXX") || exit 1
track_trash "$FIXTURE"

( cd "$FIXTURE" && git init -q . ) >/dev/null 2>&1
mkdir -p "$FIXTURE/scripts"
cat > "$FIXTURE/scripts/run-gauntlet.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub gauntlet ran"
echo "lock held: $([ -f "${GAUNTLET_LOCK_DIR:-}/pid" ] && echo yes || echo no)"
exit 0
EOF
chmod +x "$FIXTURE/scripts/run-gauntlet.sh"
# GH #158: the hook queues behind other gauntlets; keep this test's lock out of the real one.
export GAUNTLET_LOCK_DIR="$FIXTURE/gauntlet.lock"

run_hook() {
  # stdin from $1 (a file), cwd the fixture repo so `git rev-parse
  # --show-toplevel` inside the real hook resolves to the fixture, not this
  # repo.
  ( cd "$FIXTURE" && bash "$HOOK" < "$1" )
}

LOCAL_SHA="1111111111111111111111111111111111111111"
REMOTE_SHA_ZERO="0000000000000000000000000000000000000000"

# --- direct push to develop: refused, gauntlet never runs ---
in=$(mktemp)
printf 'refs/heads/feat/x %s refs/heads/develop %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* && "$out" != *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass() { [ "$1" -eq 1 ] && ok "$2" || bad "$2"; }
assert_pass "$ok" "push to refs/heads/develop is refused, gauntlet never runs"
tmp_delete "$in"

# --- delete of develop (all-zero local_sha): still refused ---
in=$(mktemp)
printf '(delete) %s refs/heads/develop %s\n' "$REMOTE_SHA_ZERO" "$LOCAL_SHA" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* ]] && ok=1 || ok=0
assert_pass "$ok" "deleting refs/heads/develop is also refused (any local_sha, including the delete sentinel)"
tmp_delete "$in"

# --- multi-ref push, only one line targets develop: refused overall ---
in=$(mktemp)
{
  printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO"
  printf 'refs/heads/y %s refs/heads/develop %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO"
} > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"refused"* ]] && ok=1 || ok=0
assert_pass "$ok" "a multi-ref push where only one line targets develop is refused"
tmp_delete "$in"

# --- a tag push: allowed, gauntlet runs ---
in=$(mktemp)
printf 'refs/tags/v1 %s refs/tags/v1 %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass "$ok" "a tag push is allowed"
tmp_delete "$in"

# --- a feat/* branch: allowed ---
in=$(mktemp)
printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass "$ok" "a feat/* branch push is allowed"
tmp_delete "$in"

# --- a fix/* branch: allowed ---
in=$(mktemp)
printf 'refs/heads/fix/y %s refs/heads/fix/y %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass "$ok" "a fix/* branch push is allowed"
tmp_delete "$in"

# --- genuinely empty stdin: allowed ---
in=$(mktemp)
: > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass "$ok" "empty stdin (nothing to push) is allowed"
tmp_delete "$in"

# --- a malformed non-empty line: fails closed, with a diagnostic ---
in=$(mktemp)
printf 'only-two-fields %s\n' "$LOCAL_SHA" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && "$out" == *"malformed"* && "$out" != *"stub gauntlet ran"* ]] && ok=1 || ok=0
assert_pass "$ok" "a malformed ref line fails closed with a diagnostic, never a silent pass-through"
tmp_delete "$in"

# --- GH #158: the gauntlet runs while the hook holds the machine-wide lock, and the lock is
# released afterwards, on success and on a failing gauntlet ---
in=$(mktemp)
printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$out" == *"lock held: yes"* && ! -e "$GAUNTLET_LOCK_DIR" ]] && ok=1 || ok=0
assert_pass "$ok" "the gauntlet runs under the lock, and the lock is gone after a passing run"
printf '#!/usr/bin/env bash\necho "stub gauntlet failed"\nexit 3\n' > "$FIXTURE/scripts/run-gauntlet.sh"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -eq 3 && ! -e "$GAUNTLET_LOCK_DIR" ]] && ok=1 || ok=0
assert_pass "$ok" "a failing gauntlet keeps its exit status and still releases the lock"
tmp_delete "$in"

# --- a refused push never touches the lock ---
in=$(mktemp)
printf 'refs/heads/feat/x %s refs/heads/develop %s\n' "$LOCAL_SHA" "$REMOTE_SHA_ZERO" > "$in"
out=$(run_hook "$in" 2>&1); rc=$?
[[ "$rc" -ne 0 && ! -e "$GAUNTLET_LOCK_DIR" ]] && ok=1 || ok=0
assert_pass "$ok" "a push refused before the gauntlet never takes the lock"
tmp_delete "$in"

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
