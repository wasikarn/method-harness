#!/usr/bin/env bash
# run-gauntlet.sh — full validation gauntlet, 3 layers in parallel:
#   validate  claude plugin validate . --strict (marketplace.json) +
#             claude plugin validate .claude-plugin/plugin.json (plugin manifest —
#             `.` alone resolves to marketplace.json when both files sit in the
#             same .claude-plugin/, confirmed via --json's "target" field
#             2026-09-14, so plugin.json was never actually checked before this;
#             --strict is dropped here only because it would fail on a single
#             known-benign warning, "CLAUDE.md not loaded as project context" —
#             true and intentional, since METHODOLOGY.md is what ships via hooks)
#   lint      bash -n (+shellcheck if installed) on tracked .sh,
#             py_compile on tracked .py, JSON parse on tracked .json
#             (2 jobs at a time; py+json in one python process)
#   tests     every tests/hooks/*.sh on disk + tests/skills/**/test*.sh
#             + tests/scripts/*.sh + tests/evals/*.sh + tests/skills/memory-lint python tests;
#             tests/mods/*.test.ts run via tests/hooks/test-cost-ledger-module.sh
#             (`claude plugin test`). test-run-gauntlet-wiring.sh fails on a tests/<dir>
#             no layer runs (GH #448).
# A full, clean, passing run records a pass for its tree (scripts/_lib/gauntlet-pass.sh, GH #735).
# Run by scripts/merge-pr.sh and scripts/sync-pr-head.sh before they push, and by git-hooks/pre-push only
# with MH_PREPUSH_FULL=1 (a plain push runs the lint layer on the changed files). harness-audit runs in
# pre-commit, not here.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
cd "$ROOT" || exit 1
# Fixture tests below git-init/commit inside temp dirs. A caller invoking us
# as a git hook (pre-push, esp. from a linked worktree) has GIT_DIR etc. set
# in its env, which hijacks those git-init calls onto the real repo instead
# of the fixture dir. Clear them before the test layer runs.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
unset MH_GATE_NO_FASTPATH  # canary-only switch; exported, it would hide fast-path regressions from the gate tests
# GAUNTLET_SHARD=i/N (GH #400): N copies of this script can run, one per runner,
# each with 1/N of the test files; validate and lint run only in shard 1. Unset
# runs everything, as before. Read into a plain var and unset, so the test files
# themselves never see it.
shard="${GAUNTLET_SHARD:-}"
unset GAUNTLET_SHARD
check_shard() {
  case "$shard" in
    "") return 0 ;;
    *[!0-9/]*|*/*/*) ;;
    [0-9]*/[0-9]*) [ "${shard%/*}" -ge 1 ] && [ "${shard%/*}" -le "${shard#*/}" ] && return 0 ;;
  esac
  echo "gauntlet: GAUNTLET_SHARD must be i/N with 1 <= i <= N, got '$shard'" >&2
  return 1
}
check_shard || exit 2
# Tests reset their state with `trash ... || true`, so without trash a row reads the last row's
# leftovers and can pass unchecked (cloud audit 2026-10-23, F4). Stop before any test runs.
command -v trash >/dev/null 2>&1 || { echo "gauntlet: trash not found on PATH (macOS: brew install trash; Linux: pip install trash-cli), refusing to run tests that reset state with it" >&2; exit 2; }
# tests/scripts/test-pipefail-grep-q-lint.sh parses every shell file with shfmt; say so up front.
# Run with no files, the scanner checks only its shfmt (on PATH, and it finds the race in
# `x | grep -q y`): a version check passes Ubuntu 24.04's apt 3.8.0, whose operators are numbers.
python3 tests/_lib/pipe_into_grep_q.py || { echo "gauntlet: no usable shfmt (macOS: brew install shfmt; Linux: pip install shfmt-py, not Ubuntu's apt package), refusing to run without the pipe-into-grep-q lint" >&2; exit 2; }
LOG="$(mktemp -d)" && [ -d "$LOG" ] || { echo "gauntlet: mktemp -d failed, refusing to run with an empty log dir" >&2; exit 1; }
# Keep $LOG on a failing run instead of trashing it unconditionally (GH #158):
# the old unconditional trap deleted the only copy of a flaky failure's full
# output before anyone could inspect it. $fail is set later in the script;
# this trap command string is re-evaluated at EXIT time, after $fail is final.
# -n "$LOG" is defense in depth behind the mktemp abort above: trash ""
# resolves to the cwd and deletes it, a documented repo incident
# (CHANGELOG.md), so a bare $LOG must never reach trash unchecked.
trap '[ -n "$LOG" ] && [ "${fail:-0}" -eq 0 ] && tmp_delete "$LOG"' EXIT

# Claude Code 2.1.289 warns "CLAUDE.md at the plugin root is not loaded as project context" and
# --strict makes it an error. It is intentional here (docs/METHODOLOGY.md ships via hooks), so a
# strict failure passes only when a plain validate succeeds and every warning it reports is that one.
validate_strict_tolerant() {
  local out
  out="$(claude plugin validate . --strict 2>&1)" && { printf '%s\n' "$out"; return 0; }
  printf '%s\n' "$out"
  local plain total benign
  plain="$(claude plugin validate . 2>&1)" || return 1
  total="$(printf '%s\n' "$plain" | sed -n 's/.*Found \([0-9][0-9]*\) warning.*/\1/p' | awk '{s+=$1} END {print s+0}')"
  benign="$(printf '%s\n' "$plain" | /usr/bin/grep -c 'CLAUDE.md at the plugin root is not loaded')"
  [ "$total" -gt 0 ] && [ "$total" -eq "$benign" ]
}

run_validate() {
  validate_strict_tolerant &&
  claude plugin validate .claude-plugin/plugin.json
}

# shellcheck source=_lib/gauntlet-lint.sh
. "$ROOT/scripts/_lib/gauntlet-lint.sh"
# shellcheck source=_lib/gauntlet-pass.sh
. "$ROOT/scripts/_lib/gauntlet-pass.sh"
# The pass cache (GH #735) keys on the tree a clean checkout starts from; read before any layer runs.
start_tree=$(gauntlet_pass_start)

# The test files the layer runs, in glob order. Kept apart from run_hook_tests so
# tests/scripts/test-run-gauntlet-wiring.sh can check the globs without running
# anything (it once ran the whole layer through a shim, which xargs bypasses).
hook_test_files() {
  local t
  for t in tests/hooks/*.sh tests/skills/test*.sh tests/skills/*/test*.sh tests/scripts/test*.sh tests/evals/test*.sh tests/skills/memory-lint/test_*.py; do
    [ -f "$t" ] && printf '%s\n' "$t"
  done | if [ -z "${shard:-}" ]; then cat; else
    # Shard i/N: greedy bin-packing by byte size, largest file first, each to the
    # lightest shard (lowest index on a tie), so the largest files (the three
    # test-gates*.sh parts and test-subagent-git-guard.sh, ~half of all test time) spread out. Byte size is
    # a rough proxy for run time, but needs no timing table to keep current.
    # Same input gives the same split on every runner; output keeps glob order.
    # One wc for all files, not one per file; head drops its "total" line. A read loop, not
    # mapfile, so macOS's stock bash 3.2 still runs it.
    local files=()
    while IFS= read -r t; do files+=("$t"); done
    [ "${#files[@]}" -gt 0 ] || return 0
    wc -c "${files[@]}" | head -n "${#files[@]}" |
      awk '{ s = $1; sub(/^ *[0-9]+ /, ""); print s, NR, $0 }' | LC_ALL=C sort -k1,1nr -k3,3 |
      awk -v i="${shard%/*}" -v n="${shard#*/}" '
        { b = 1; for (k = 2; k <= n; k++) if (sum[k] < sum[b]) b = k
          sum[b] += $1; if (b == i) print $2, $3 }' |
      sort -n | cut -d' ' -f2
  fi
  return 0
}

run_hook_tests() {
  local rc=0 t
  # Redirect the gate-verdict journal for the whole hook-test layer: several
  # suites (the test-gates*.sh files hold ~1700 allow/deny/ask rows) exercise gates
  # whose journal() call writes to $HOME/.local/share/kbg/metrics/
  # gate-decisions.jsonl by default. Without this, every local
  # run-gauntlet.sh/pre-push would silently append synthetic rows to the
  # operator's real journal, corrupting the analytics it exists to produce.
  # MH_GATE_JOURNAL_PATH is a narrow override (hooks/gates/_journal.py),
  # deliberately NOT a full HOME swap: an earlier version of this fix
  # exported a throwaway HOME for the whole test layer and broke
  # PyYAML-dependent tests (test-ste-lint.sh, harness-audit's YAML checks) --
  # PyYAML is resolved via the real $HOME's user site-packages, so replacing
  # HOME wholesale has far more blast radius than this one write path needs.
  local JOURNAL_TMP
  # A fixture gauntlet that a test runs must not write the operator's pass cache.
  export GAUNTLET_PASS_CACHE=0
  JOURNAL_TMP="$(mktemp -d)"
  trap 'tmp_delete "$JOURNAL_TMP"' RETURN
  export MH_GATE_JOURNAL_PATH="$JOURNAL_TMP/gate-decisions.jsonl"
  # Test files run in parallel (GAUNTLET_JOBS, default 4 locally, 1 when CI is
  # set), each with its own journal file and output file, then print in glob
  # order so the log reads the same as a serial run. Biggest files start first
  # (`ls -S`, longest job first): test-gates*.sh and test-subagent-git-guard.sh
  # are ~half of all test time, so they must not queue behind the cheap files.
  # Kept at 4, not nproc: the box is shared and timing rows (GH #158) fail under
  # heavy load. CI stays serial: its runner is slower with fewer cores, and the
  # 8 s rows already have only ~1.1x margin there; 4 concurrent files timed one out.
  local TDIR="$JOURNAL_TMP/t" o
  mkdir -p "$TDIR"
  hook_test_files | xargs ls -S |
    xargs -P "${GAUNTLET_JOBS:-$([ -n "${CI:-}" ] && echo 1 || echo 4)}" -I{} bash -c \
      'o="$1/${2//\//_}"; case "$2" in *.py) interp=python3;; *) interp=bash;; esac
       MH_GATE_JOURNAL_PATH="$o.jsonl" "$interp" "$2" >"$o.out" 2>&1; echo $? >"$o.rc"' _ "$TDIR" {}
  local failed=""
  for t in $(hook_test_files); do
    o="$TDIR/${t//\//_}"
    echo "--- $t"
    cat "$o.out"
    [ "$(cat "$o.rc" 2>/dev/null)" = 0 ] || { rc=1; failed="$failed $t"; }
  done
  # Name the culprits (GH #387): a red CI log runs to thousands of lines. Then the failing rows
  # themselves (GH #158), up to 3 per file, so a load flake reads differently from a regression
  # without a re-run; a file with no marked row (a crash) shows its last output line instead.
  local row
  for t in $failed; do
    o="$TDIR/${t//\//_}"
    row=$(/usr/bin/grep -E '❌|FAIL|not ok|rc 124' "$o.out" | /usr/bin/grep -vE '^ *(✅|PASS|SKIP|ok[: ])' | head -n 3)
    [ -n "$row" ] || row=$(tail -n 1 "$o.out")
    printf '%s\n' "$row" | sed "s|^ *|failed-at: $t: |"
  done
  [ -z "$failed" ] || echo "failing:$failed"
  return "$rc"
}

# GH #158: name leftover CPU-heavy processes (a stray stress run) before the timing rows run, and
# again on failure, so a load flake can be told from a regression. Warn-only, never fails the run.
# shellcheck source=_lib/stray-procs.sh
. "$ROOT/scripts/_lib/stray-procs.sh"
stray_procs_report

p1="" p2=""
if [ -z "$shard" ] || [ "${shard%/*}" -eq 1 ]; then
  # check-observer-contract.sh (GH #443): the mh module stays a turn.complete observer.
  { run_validate && bash scripts/check-observer-contract.sh "$ROOT"; } >"$LOG/validate" 2>&1 & p1=$!
  git ls-files | run_lint >"$LOG/lint" 2>&1 & p2=$!
fi
run_hook_tests >"$LOG/tests" 2>&1 & p3=$!

fail=0
report() {
  local name="$1" pid="$2"
  if [ -z "$pid" ]; then
    echo "SKIP  $name (runs in shard 1, this is shard $shard)"
  elif wait "$pid"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"; fail=1
    sed 's/^/      /' "$LOG/$name"
  fi
}
report validate "$p1"
report lint "$p2"
report tests "$p3"
if [ "$fail" -eq 0 ]; then
  echo "gauntlet: all layers passed"
  gauntlet_pass_record "$fail" "$shard" "$start_tree"
else
  echo "gauntlet: FAILED (full logs kept at $LOG)" >&2
  stray_procs_report  # before the lists: the last line stays the failing: list (GH #387)
  /usr/bin/grep '^failed-at:' "$LOG/tests" >&2
  /usr/bin/grep '^failing:' "$LOG/tests" >&2
fi
exit "$fail"
