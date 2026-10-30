#!/usr/bin/env bash
# test-gauntlet-git-env-isolation.sh — regression test for the pre-push
# GIT_DIR isolation fix in run-gauntlet.sh (Codex review finding, 2026-09-06).
# A poisoned GIT_DIR in the calling process (e.g. pre-push fired from a
# linked worktree) must not let a fixture `git init` inside a temp dir
# re-target the real repo instead of creating an isolated one.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet GIT_DIR isolation ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
# A missing TMPDIR makes mktemp print "" and `trash ""` trashes the cwd: stop, and let
# _cleanup_trash (which drops empties) do the trashing.
DECOY=$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-decoy.XXXXXX") || exit 1
track_trash "$DECOY"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-fixture.XXXXXX") || exit 1
track_trash "$FIXTURE"

( cd "$DECOY" && git init -q -b decoy-original . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m decoy-canary ) >/dev/null 2>&1
decoy_head_before=$(git -C "$DECOY" rev-parse HEAD)

REQUIRED_VARS="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE"
UNSET_LINE=$(/usr/bin/grep -E '^unset GIT_' "$GAUNTLET" || true)
if [ -z "$UNSET_LINE" ]; then
  bad "run-gauntlet.sh has no 'unset GIT_...' isolation line"
else
  unset_line_no=$(/usr/bin/grep -n '^unset GIT_' "$GAUNTLET" | head -1 | cut -d: -f1)
  # Unanchored: since GH #749 the launch sits inside the --level branches.
  invoke_line_no=$(/usr/bin/grep -n 'run_hook_tests >"\$LOG/tests"' "$GAUNTLET" | head -1 | cut -d: -f1)
  if [ -n "$invoke_line_no" ] && [ "$unset_line_no" -lt "$invoke_line_no" ]; then
    ok "GIT_* unset happens before run_hook_tests is launched"
  else
    bad "GIT_* unset is positioned after run_hook_tests launches (or launch line not found)"
  fi

  # Named per-variable check, not just "grep found something": a line-wrap,
  # typo, or dropped name in run-gauntlet.sh's unset statement must fail this
  # loudly instead of passing on whatever fragment grep happened to capture.
  unset_result=$(
    for v in $REQUIRED_VARS; do export "$v=x"; done
    eval "$UNSET_LINE"
    missed=""
    for v in $REQUIRED_VARS; do
      declare -p "$v" >/dev/null 2>&1 && missed="$missed $v"
    done
    [ -z "$missed" ] && echo OK || echo "MISSED:$missed"
  )
  if [ "$unset_result" = "OK" ]; then
    ok "extracted unset statement clears all 7 named GIT_* vars"
  else
    bad "extracted unset statement did not clear: ${unset_result#MISSED:}"
  fi

  ( export GIT_DIR="$DECOY/.git"
    eval "$UNSET_LINE"
    cd "$FIXTURE" && git init -q -b probe . \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture-canary
  ) >/dev/null 2>&1

  if [ -d "$FIXTURE/.git" ]; then
    ok "fixture git init creates an isolated repo under a poisoned GIT_DIR"
  else
    bad "fixture git init did not create $FIXTURE/.git -- GIT_DIR leaked in"
  fi

  decoy_head_after=$(git -C "$DECOY" rev-parse HEAD 2>/dev/null || echo "?")
  if [ "$decoy_head_after" = "$decoy_head_before" ]; then
    ok "decoy repo HEAD untouched"
  else
    bad "decoy repo HEAD moved ($decoy_head_before -> $decoy_head_after) -- fixture commit leaked into it"
  fi

  decoy_bare=$(git -C "$DECOY" config --get core.bare 2>/dev/null || echo "false")
  if [ "$decoy_bare" != "true" ]; then
    ok "decoy repo core.bare untouched"
  else
    bad "decoy repo core.bare flipped to true -- GIT_DIR leaked into fixture git-init"
  fi
fi

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
