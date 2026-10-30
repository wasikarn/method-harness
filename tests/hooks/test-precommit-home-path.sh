#!/usr/bin/env bash
# Pins the pre-commit home-path ban (step 4): it reads the INDEX copy of every staged file, binary
# and space-named files included, prints one message per hit, and searches nothing when nothing is
# staged. Extracts step 4 and the staged_z helper from git-hooks/pre-commit and evals them in a
# throwaway repo with its own HOME. Home paths are built at run time so this file passes the ban.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
HOOK="$ROOT/git-hooks/pre-commit"
d="$(mktemp -d)"
[ -n "$d" ] && [ -d "$d" ] || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'tmp_delete "$d"' EXIT
helper=$(/usr/bin/grep -E '^staged_z\(\) ' "$HOOK")
body=$(sed -n '/^# 4\. hardcoded home paths/,/^done < <(/p' "$HOOK")
[ -n "$helper" ] && [ -n "$body" ] || { echo "FAIL: step 4 or staged_z not found in git-hooks/pre-commit"; exit 1; }

# A git shim on PATH logs each grep call, so "nothing staged, nothing searched" is observable.
real_git=$(command -v git)
mkdir -p "$d/bin" "$d/home" "$d/repo"
printf '#!/bin/sh\n[ "$2" = grep ] && echo grep >>"%s/grep.log"\nexec "%s" "$@"\n' "$d" "$real_git" >"$d/bin/git"
chmod +x "$d/bin/git"
export HOME="$d/home" PATH="$d/bin:$PATH" GIT_CONFIG_NOSYSTEM=1
cd "$d/repo" || exit 1
git init -q . && git config user.email t@example.com && git config user.name t

fail=0
run() { # prints the step's stderr, then "fail=<n>"
  local fail=0
  eval "$helper"
  eval "$body" 2>&1
  echo "fail=$fail"
}
check() { # name, want, got
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

: >"$d/grep.log"
check "nothing staged: no message, no failure" "fail=0" "$(run)"
check "nothing staged: git grep never runs" "" "$(cat "$d/grep.log")"

home_a=$(printf '/%s/alice/x' Users)
home_b=$(printf 'proj-%s-bob' Users)
printf 'ok\n' >clean.txt
printf 'see %s\n' "$home_a" >"has space.txt"
printf 'a\000b %s\000\n' "$home_b" >bin.dat
printf 'clean in the index\n' >dirty.txt
printf 'x %s\n' "$home_a" >'[glob].txt'
git add clean.txt "has space.txt" bin.dat dirty.txt '[glob].txt'
printf 'dirty %s\n' "$home_a" >dirty.txt  # working tree only: the index copy is what gets committed
printf 'untracked %s\n' "$home_a" >untracked.txt
want=$(printf '%s\n' \
  "pre-commit: hardcoded home path in [glob].txt — use \$HOME or ~" \
  "pre-commit: hardcoded home path in bin.dat — use \$HOME or ~" \
  "pre-commit: hardcoded home path in has space.txt — use \$HOME or ~" \
  "fail=1")
check "staged hits: one message each (binary, space, glob name), index copy only" "$want" "$(run)"

git rm -q --cached "has space.txt" bin.dat '[glob].txt'
check "only clean files staged: no message" "fail=0" "$(run)"

# A staged file named like a glob must not widen the search to committed files it would match.
printf 'committed %s\n' "$home_a" >old.txt
git add old.txt && git commit -qm old --no-gpg-sign && git rm -q --cached clean.txt dirty.txt
printf 'ok\n' >'*.txt'
git --literal-pathspecs add '*.txt'
check "a staged file named *.txt is searched as itself, not as a glob" "fail=0" "$(run)"

[ "$fail" -eq 0 ] && echo "precommit-home-path: all passed" || { echo "precommit-home-path: FAILED"; exit 1; }
