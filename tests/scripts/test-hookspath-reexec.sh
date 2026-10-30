#!/usr/bin/env bash
# test-hookspath-reexec.sh — GH #743: when core.hooksPath points at ANOTHER checkout's absolute
# git-hooks, git-hooks/pre-commit and pre-push warn once and exec the work tree's own hook.
# Stubs carry the real hooks' re-exec block (cut from the repo copy) plus a marker line, so a
# revert of the block empties the stubs' guard and every row below fails.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE MH_HOOK_REEXEC
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

echo "=== hooks: re-exec the work tree's own hook when core.hooksPath points elsewhere ==="
source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/hookspath-reexec.XXXXXX") || exit 1
track_trash "$T"
T=$(cd -P "$T" && pwd -P)
A="$T/a"; B="$T/b"
g() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }

mkdir -p "$A"
g "$A" init -q .
mkdir -p "$A/git-hooks"
for h in pre-commit pre-push; do
  {
    echo '#!/usr/bin/env bash'
    awk '/^# GH #743/{on=1} on{print} on&&/^fi$/{exit}' "$ROOT/git-hooks/$h"
    # shellcheck disable=SC2016 # expanded when the stub runs
    echo 'echo "$(cd -P "$(dirname "$0")" && pwd -P) $(cat)" >> "'"$T"'/ran"'
  } > "$A/git-hooks/$h"
  chmod +x "$A/git-hooks/$h"
done
g "$A" add git-hooks
g "$A" commit -q --no-verify -m init
g "$A" worktree add -q "$B" -b other
own_b="$B/git-hooks"
# Rows 3 and 4 pass trivially without the block, so they also require it in both stubs.
# shellcheck disable=SC2034 # read inside check's eval strings
guard='/usr/bin/grep -q MH_HOOK_REEXEC=1 "$A/git-hooks/pre-commit" && /usr/bin/grep -q MH_HOOK_REEXEC=1 "$A/git-hooks/pre-push"'

# Row 1: absolute core.hooksPath at A's git-hooks, commit in B: B's own hook runs, warning printed.
g "$A" config core.hooksPath "$A/git-hooks"
: > "$T/ran"
g "$B" commit -q --allow-empty -m x 2> "$T/err" < /dev/null
check '[ "$(cut -d" " -f1 "$T/ran")" = "$own_b" ]' "pre-commit: work tree's own hook ran, not the other checkout's"
check '[ "$(wc -l < "$T/ran")" -eq 1 ]' "pre-commit: hook body ran exactly once"
check '/usr/bin/grep -q "core.hooksPath is .$A/git-hooks.*git config core.hooksPath git-hooks" "$T/err"' "pre-commit: warning names the configured path and the fix"

# Row 2: pre-push via the other checkout's path, run from B: stdin ref lines reach B's hook intact.
: > "$T/ran"
refs="refs/heads/other 1111111111111111111111111111111111111111 refs/heads/other 0000000000000000000000000000000000000000"
(cd "$B" && printf '%s\n' "$refs" | "$A/git-hooks/pre-push" origin url 2> "$T/err")
check '[ "$(cat "$T/ran")" = "$own_b $refs" ]' "pre-push: own hook ran and got the ref lines intact"
check '/usr/bin/grep -q "git config core.hooksPath git-hooks" "$T/err"' "pre-push: warning printed"

# Row 3: relative core.hooksPath: no warning, no re-exec.
g "$A" config core.hooksPath git-hooks
: > "$T/ran"
g "$B" commit -q --allow-empty -m y 2> "$T/err" < /dev/null
check 'eval "$guard" && [ "$(cut -d" " -f1 "$T/ran")" = "$own_b" ] && [ "$(wc -l < "$T/ran")" -eq 1 ]' "relative path: own hook ran once"
check 'eval "$guard" && [ ! -s "$T/err" ]' "relative path: no warning"

# Row 4: a symlink to B's own git-hooks resolves to the same dir: no warning, no loop.
ln -s "$own_b" "$T/link"
g "$A" config core.hooksPath "$T/link"
: > "$T/ran"
g "$B" commit -q --allow-empty -m z 2> "$T/err" < /dev/null
check 'eval "$guard" && [ "$(wc -l < "$T/ran")" -eq 1 ] && [ ! -s "$T/err" ]' "symlinked same dir: ran once, no warning"

# Row 4b: marker already set (a re-exec happened): never exec again, even from the other path.
g "$A" config core.hooksPath "$A/git-hooks"
: > "$T/ran"
MH_HOOK_REEXEC=1 g "$B" commit -q --allow-empty -m w 2> "$T/err" < /dev/null
check 'eval "$guard" && [ "$(wc -l < "$T/ran")" -eq 1 ] && [ ! -s "$T/err" ]' "re-exec marker set: no second exec"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
