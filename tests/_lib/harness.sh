#!/usr/bin/env bash
# harness.sh — shared test scaffolding for tests/hooks/test-fragments-{arm,
# capture,surface}.sh (originally 5 consumers including the now-removed
# tests/hooks/test-handoff-{nudge,surface}.sh, see git history): the
# fresh_tmpdir/fresh_repo/_cleanup_trash trio that used to be 5 separate
# copies, 3 of which were missing the empty-string guard the other 2 had --
# the exact bug that moved this repo's working tree to Trash mid-session
# (trash "" deletes the process's cwd). One definition so that guard can't
# be present in some copies and missing in others again.
#
# Not matched by any of scripts/run-gauntlet.sh's five test-discovery globs
# (tests/hooks/*.sh, tests/skills/test*.sh, tests/skills/*/test*.sh,
# tests/scripts/test*.sh, tests/evals/test*.sh) -- this lives under
# tests/_lib/, so it is linted (git ls-files '*.sh') but never executed as
# a test itself. Source it, don't execute it.
#
# Caller contract: this file declares EXTRA_TRASH and the functions below;
# it never registers the EXIT trap itself, so each caller still does its
# own `trap _cleanup_trash EXIT` after sourcing.

# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

EXTRA_TRASH=()

# _HARNESS_ROOT: one real tmpdir created here, at source time, in the
# caller's own shell -- not inside a function invoked via $(...) (deep-audit
# finding, live-reproduced: every caller uses `T=$(fresh_tmpdir)`, and a
# function's ENTIRE body runs in a forked subshell when called that way, so
# an EXTRA_TRASH+=(...) done from inside fresh_tmpdir never reached the
# parent's array -- `${#EXTRA_TRASH[@]}` stayed 0 after every such call,
# meaning fresh_tmpdir's output was never actually cleaned up). fresh_tmpdir
# below now mktemps a subdir of this already-live root instead of
# registering itself into an array, so no subshell-scoped mutation is
# needed for the common case at all.
_HARNESS_ROOT=$(mktemp -d)

# tmp_delete <path>...: permanent delete of this test's own temp paths, from
# scripts/_lib/tmp-delete.sh (python3 captured at source time; GH #724, #729).
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/_lib/tmp-delete.sh"

# track_trash <path>: register <path> for cleanup at _cleanup_trash time.
# Filters empty unconditionally. For a caller's own mktemp/mkdir calls that
# don't go through fresh_tmpdir (a single mktemp file, a manually-named
# dir) -- call this directly at the test file's own top level, never from
# inside a function invoked via $(...), or it inherits the same bug.
track_trash() {
  [ -n "${1:-}" ] && EXTRA_TRASH+=("$1")
  return 0
}

# fresh_tmpdir: a fresh subdir of _HARNESS_ROOT. Prints the path. No
# per-call registration needed -- _cleanup_trash removes _HARNESS_ROOT
# itself, once, which recursively takes every fresh_tmpdir with it.
fresh_tmpdir() {
  local d
  d=$(mktemp -d "$_HARNESS_ROOT/t.XXXXXX")
  printf '%s' "$d"
}

# fresh_repo: fresh_tmpdir, git-initialized. Prints the path.
fresh_repo() {
  local d
  d=$(fresh_tmpdir)
  (cd "$d" && git init -q && git config user.email t@t.com && git config user.name t) >/dev/null 2>&1
  printf '%s' "$d"
}

# _cleanup_trash: the EXIT trap body. Every target -- _HARNESS_ROOT (every
# fresh_tmpdir at once), $FAKE_HOME (if the caller set it), plus every
# tracked EXTRA_TRASH entry -- is filtered to non-empty before the delete ever
# sees it: `trash ""` deletes the process's current working directory,
# confirmed live (this repo's working tree was moved to Trash mid-session
# by exactly this bug, in a copy of this function that lacked the filter).
# The delete is tmp_delete, one target per call, so a refused target (not
# under a temp root) is reported on stderr without blocking the others.
_cleanup_trash() {
  local t targets=()
  [ -n "${_HARNESS_ROOT:-}" ] && targets+=("$_HARNESS_ROOT")
  [ -n "${FAKE_HOME:-}" ] && targets+=("$FAKE_HOME")
  for t in "${EXTRA_TRASH[@]:-}"; do
    [ -n "$t" ] && targets+=("$t")
  done
  for t in "${targets[@]:-}"; do
    [ -n "$t" ] && tmp_delete "$t"
  done
  return 0
}
