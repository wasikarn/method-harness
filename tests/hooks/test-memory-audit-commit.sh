#!/usr/bin/env bash
# memory-audit-commit unit tests. Isolates a fake $HOME and a fake project
# cwd (not a git repo, so scripts/_lib/memory-dir.py's git-derivation falls
# through to its non-git cwd fallback, same physical path `pwd -P` would give)
# so real ~/.claude/projects state is never touched.
# Run standalone: bash tests/hooks/test-memory-audit-commit.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/stop/memory-audit-commit.sh"

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
# A missing TMPDIR makes mktemp print "" and `trash ""` trashes the cwd: stop before FAKE_HOME and the
# rest are built on "", and let _cleanup_trash (which drops empties) do the trashing.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kbg-memory-audit-commit-test.XXXXXX") || exit 1
track_trash "$TMP"

pass=0
fail=0

PROJECT_DIR="$TMP/project"
FAKE_HOME="$TMP/home"
mkdir -p "$PROJECT_DIR" "$FAKE_HOME/.claude/state"

PHYSPWD=$(cd "$PROJECT_DIR" && pwd -P)
ENC=$(printf '%s' "$PHYSPWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
MEMDIR="$FAKE_HOME/.claude/projects/$ENC/memory"
LOCKDIR="$FAKE_HOME/.claude/state/memory-audit-commit-lock-$ENC"
MARKER_GLOB="$FAKE_HOME/.claude/state/memory-audit-commit-fail-$ENC-"

init_memdir() {
  trash "$MEMDIR" 2>/dev/null || true
  mkdir -p "$MEMDIR"
  ( cd "$MEMDIR" && git init -q && git config user.email "t@example.com" && git config user.name "t" )
}

clear_state() {
  rm -rf "$LOCKDIR" 2>/dev/null
  shopt -s nullglob
  rm -f "$MARKER_GLOB"* 2>/dev/null
  shopt -u nullglob
}

markers() {
  shopt -s nullglob
  local m=("$MARKER_GLOB"*)
  shopt -u nullglob
  printf '%s\n' "${m[@]}"
}

marker_count() {
  shopt -s nullglob
  local m=("$MARKER_GLOB"*)
  shopt -u nullglob
  echo "${#m[@]}"
}

run_hook() {
  ( cd "$PROJECT_DIR" && HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" )
}

run_hook_env() {
  # $@ = extra NAME=value pairs to export for this invocation only.
  ( cd "$PROJECT_DIR" && HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" env "$@" bash "$HOOK" )
}

check() {
  local desc="$1" ok="$2"
  if [ "$ok" -eq 0 ]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

echo "=== memory-audit-commit hook (Stop) ==="
echo ""

echo "--- baseline: clean commit succeeds, no marker ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/topic.md"
run_hook
ok=1; [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "dirty .md file gets committed" "$ok"
ok=1; [ "$(marker_count)" -eq 0 ] && ok=0
check "no failure marker on a successful commit" "$ok"
ok=1; [ ! -d "$LOCKDIR" ] && ok=0
check "lock dir removed after a normal run" "$ok"

echo ""
echo "--- H6 (2026-09-20): a failed git add/commit now writes a per-attempt marker ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/topic2.md"
# A stale index.lock deterministically makes git add fail, regardless of
# git version or global config on the host running this test.
touch "$MEMDIR/.git/index.lock"
run_hook
ok=1; [ "$(marker_count)" -eq 1 ] && ok=0
check "git add failure writes exactly one marker" "$ok"
ok=1; command grep -qi "index.lock" "$MARKER_GLOB"* 2>/dev/null && ok=0
check "marker captures the real git stderr" "$ok"
ok=1; command grep -qE '^acquisition_ts=[0-9]+(\.[0-9]+)?$' "$MARKER_GLOB"* 2>/dev/null && ok=0
check "marker embeds its own acquisition timestamp" "$ok"
ok=1; [ -n "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "the .md file is still uncommitted after the failure" "$ok"

echo ""
echo "--- marker clears on the next successful commit ---"
rm -f "$MEMDIR/.git/index.lock"
run_hook
ok=1; [ "$(marker_count)" -eq 0 ] && ok=0
check "marker is cleared once the commit succeeds" "$ok"
ok=1; [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "the previously-stuck file is now committed" "$ok"

echo ""
echo "--- untouched behavior: not opted in / clean tree still no-op silently ---"
trash "$MEMDIR" 2>/dev/null || true
clear_state
OUT=$(run_hook)
ok=1; [ -z "$OUT" ] && ok=0
check "no memory dir at all -> silent no-op" "$ok"
ok=1; [ "$(marker_count)" -eq 0 ] && ok=0
check "no marker written when not opted in" "$ok"

init_memdir
OUT=$(run_hook)
ok=1; [ -z "$OUT" ] && ok=0
check "clean tree (nothing to commit) -> silent no-op" "$ok"

echo ""
echo "--- GH #379: the resolver is loaded once per Stop, opted in or not ---"
# A logging stub stands in for the resolver: it records each load, then exposes the real one's functions.
STUB_ROOT="$TMP/stub-root"
RESOLVER_LOG="$TMP/resolver-calls.log"
mkdir -p "$STUB_ROOT/scripts/_lib"
cat > "$STUB_ROOT/scripts/_lib/memory-dir.py" <<EOF
import runpy, sys
with open("$RESOLVER_LOG", "a") as f:
    f.write("call\n")
globals().update(runpy.run_path("$ROOT/scripts/_lib/memory-dir.py"))
EOF
run_hook_stub() {
  : > "$RESOLVER_LOG"
  ( cd "$PROJECT_DIR" && HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$STUB_ROOT" bash "$HOOK" )
}
trash "$MEMDIR/.git" 2>/dev/null || true
clear_state
run_hook_stub
ok=1; [ "$(cat "$RESOLVER_LOG")" = "call" ] && ok=0
check "store without .git: one resolver load (log: $(tr '\n' '|' < "$RESOLVER_LOG"))" "$ok"
init_memdir
echo "n/a" > "$MEMDIR/stub-case.md"
run_hook_stub
ok=1; [ "$(cat "$RESOLVER_LOG")" = "call" ] \
  && [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "opted-in store: one resolver load for dir and enc, and the commit lands" "$ok"

echo ""
echo "--- a fabricated OLD marker is swept by a later successful invocation ---"
init_memdir
clear_state
OLD_TS=$(( $(date +%s) - 1000 ))
printf 'acquisition_ts=%s\nold stale failure\n' "$OLD_TS" > "${MARKER_GLOB}99991"
run_hook   # clean tree -> still a "success" path, sweep runs
ok=1; [ ! -f "${MARKER_GLOB}99991" ] && ok=0
check "a marker older than this run's acquisition time is swept" "$ok"

echo ""
echo "--- a fabricated marker timestamped AFTER this run's start is NOT swept (protects a concurrent waiter) ---"
init_memdir
clear_state
FUTURE_TS=$(( $(date +%s) + 1000 ))
printf 'acquisition_ts=%s\nconcurrent waiter, still in flight\n' "$FUTURE_TS" > "${MARKER_GLOB}99992"
run_hook   # clean tree -> success path; this run's own ACQUIRE_TS is well before FUTURE_TS
ok=1; [ -f "${MARKER_GLOB}99992" ] && ok=0
check "a marker at/after this run's own acquisition time survives (ordering, not identity, protects it)" "$ok"
rm -f "${MARKER_GLOB}99992"

echo ""
echo "--- the sweep never deletes a marker of a project whose ENC extends this one (proj vs proj-v2) ---"
init_memdir
clear_state
OLD_TS=$(( $(date +%s) - 1000 ))
OTHER_MARKER="${MARKER_GLOB}v2-99993"   # = memory-audit-commit-fail-<ENC>-v2-<pid>, another store's marker
printf 'acquisition_ts=%s\nother project failure\n' "$OLD_TS" > "$OTHER_MARKER"
run_hook   # clean tree -> success path, sweep runs
ok=1; [ -f "$OTHER_MARKER" ] && ok=0
check "an older marker of ENC-v2 survives this ENC's sweep" "$ok"
rm -f "$OTHER_MARKER"

echo ""
echo "--- real concurrent invocations: lock serializes, both changes land, no residue ---"
init_memdir
clear_state
echo "a" > "$MEMDIR/concurrent-a.md"
echo "b" > "$MEMDIR/concurrent-b.md"
run_hook & p1=$!
run_hook & p2=$!
wait "$p1"; wait "$p2"
ok=1; [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "both concurrent invocations' changes end up committed" "$ok"
ok=1; [ "$(marker_count)" -eq 0 ] && ok=0
check "no marker left behind after a clean concurrent pair" "$ok"
ok=1; [ ! -d "$LOCKDIR" ] && ok=0
check "no orphaned lock dir after a clean concurrent pair" "$ok"

echo ""
echo "--- lock-timeout: a genuinely held lock makes the waiter give up and write its own marker ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/timeout-case.md"
sleep 30 & HOLDER_PID=$!
mkdir -p "$LOCKDIR"
printf '%s\n' "$HOLDER_PID" > "$LOCKDIR/pid"
ps -o lstart= -p "$HOLDER_PID" > "$LOCKDIR/start"
START_T=$(date +%s)
run_hook_env MH_MEMORY_LOCK_WAIT_MAX=1 MH_MEMORY_LOCK_POLL_INTERVAL=0.2
END_T=$(date +%s)
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
ok=1; [ $((END_T - START_T)) -le 4 ] && ok=0
check "waiter gives up within the bounded wait, does not hang (took $((END_T - START_T))s)" "$ok"
ok=1; [ "$(marker_count)" -eq 1 ] && ok=0
check "waiter writes exactly one timeout marker" "$ok"
ok=1; command grep -qi "lock wait timed out" "$MARKER_GLOB"* 2>/dev/null && ok=0
check "timeout marker names the cause" "$ok"
ok=1; [ -n "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "the dirty file was never committed while the lock was held elsewhere" "$ok"
rm -rf "$LOCKDIR" 2>/dev/null
clear_state

echo ""
echo "--- stale-lock reclaim: a dead PID's lock is reclaimed, not waited out ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/stale-case.md"
bash -c 'exit 0' & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null   # now guaranteed not running
mkdir -p "$LOCKDIR"
printf '%s\n' "$DEAD_PID" > "$LOCKDIR/pid"
printf 'stale-start-marker\n' > "$LOCKDIR/start"
START_T=$(date +%s)
run_hook_env MH_MEMORY_LOCK_WAIT_MAX=5 MH_MEMORY_LOCK_POLL_INTERVAL=0.2
END_T=$(date +%s)
ok=1; [ $((END_T - START_T)) -le 3 ] && ok=0
check "a dead-PID lock is reclaimed quickly, not waited out to the bound (took $((END_T - START_T))s)" "$ok"
ok=1; [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "the file committed after reclaiming the dead holder's lock" "$ok"
ok=1; [ "$(marker_count)" -eq 0 ] && ok=0
check "no timeout marker written when the stale lock was reclaimed" "$ok"

echo ""
echo "--- live-holder-not-reclaimed: a real running PID with an aged lock mtime is never stolen ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/live-holder-case.md"
sleep 30 & HOLDER_PID=$!
mkdir -p "$LOCKDIR"
printf '%s\n' "$HOLDER_PID" > "$LOCKDIR/pid"
ps -o lstart= -p "$HOLDER_PID" > "$LOCKDIR/start"
# Age the lock dir's own mtime far past the stale-metadata threshold, to
# prove age alone (with valid, live, identity-matching metadata) never
# triggers reclaim.
touch -t 202001010000 "$LOCKDIR" 2>/dev/null || touch -d "2020-01-01" "$LOCKDIR" 2>/dev/null
run_hook_env MH_MEMORY_LOCK_WAIT_MAX=1 MH_MEMORY_LOCK_POLL_INTERVAL=0.2
ok=1; [ -d "$LOCKDIR" ] && [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$HOLDER_PID" ] && ok=0
check "the live holder's lock dir is untouched despite its aged mtime" "$ok"
ok=1; [ -n "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "the file was not committed (lock correctly not reclaimed)" "$ok"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
rm -rf "$LOCKDIR" 2>/dev/null
clear_state

echo ""
echo "--- (2026-09-21) unset / relative HOME: skip silently, never crash under set -u or write into cwd ---"
init_memdir
clear_state
echo "n/a" > "$MEMDIR/topic3.md"
before=$(ls -A "$PROJECT_DIR" | wc -l | tr -d ' ')
OUT=$( cd "$PROJECT_DIR" && env -u HOME CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" </dev/null 2>&1 ); rc=$?
after=$(ls -A "$PROJECT_DIR" | wc -l | tr -d ' ')
ok=1; [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ "$before" = "$after" ] && ok=0
check "unset HOME -> rc 0, silent, nothing written into cwd (rc=$rc out=<$OUT>)" "$ok"
# Discriminating relative-HOME case: plant a dirty store where HOME=rel WOULD
# resolve (cwd/rel/...). An unguarded hook commits it and mkdirs
# rel/.claude/state inside the project cwd; the guard must do neither.
REL_MEMDIR="$PROJECT_DIR/rel/.claude/projects/$ENC/memory"
mkdir -p "$REL_MEMDIR"
( cd "$REL_MEMDIR" && git init -q && git config user.email "t@example.com" && git config user.name "t" )
echo "n/a" > "$REL_MEMDIR/topic.md"
OUT=$( cd "$PROJECT_DIR" && HOME=rel CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" </dev/null 2>&1 ); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ ! -d "$PROJECT_DIR/rel/.claude/state" ] \
  && [ -n "$(git -C "$REL_MEMDIR" status --porcelain)" ] && ok=0
check "relative HOME -> rc 0, silent, no rel/.claude/state in cwd, planted store left uncommitted (rc=$rc out=<$OUT>)" "$ok"
trash "$PROJECT_DIR/rel" 2>/dev/null || true

echo ""
echo "--- linked worktree resolves to the SAME memory store as the main tree ---"
GITREPO="$TMP/gitrepo"
mkdir -p "$GITREPO"
( cd "$GITREPO" && git init -q && git config user.email "t@example.com" && git config user.name "t" \
  && echo "x" > f.txt && git add f.txt && git commit -q -m init )
WT="$TMP/gitrepo-wt"
( cd "$GITREPO" && git worktree add -q -b test-wt "$WT" >/dev/null 2>&1 )
# Physical path, not the raw (possibly symlinked, e.g. macOS TMPDIR under
# /var -> /private/var) $GITREPO string -- git itself resolves symlinks when
# deriving --git-common-dir, so the hook's own ENC would otherwise never
# match one computed from the logical path.
MAIN_ENC="$(cd "$GITREPO" && pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
MAIN_MEMDIR="$FAKE_HOME/.claude/projects/$MAIN_ENC/memory"
mkdir -p "$MAIN_MEMDIR"
( cd "$MAIN_MEMDIR" && git init -q && git config user.email "t@example.com" && git config user.name "t" )
echo "from-worktree" > "$MAIN_MEMDIR/from-worktree.md"
( cd "$WT" && HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" )
ok=1; [ -z "$(git -C "$MAIN_MEMDIR" status --porcelain)" ] && ok=0
check "a Stop hook run from inside a linked worktree commits to the MAIN tree's memory store" "$ok"
git -C "$GITREPO" worktree remove -f "$WT" 2>/dev/null || true
trash "$GITREPO" "$MAIN_MEMDIR" 2>/dev/null || true

# One python launch per Stop for an opted-in store: memory dir, enc and the
# acquisition timestamp come from one call (was 3 launches, 2026-10-22).
clear_state
init_memdir
echo "py-count" > "$MEMDIR/py-count.md"
PY_SHIM="$TMP/pyshim"; mkdir -p "$PY_SHIM"
printf '#!/bin/sh\necho spawn >> "%s/py.log"\nexec "%s" "$@"\n' "$TMP" "$(command -v python3)" > "$PY_SHIM/python3"
chmod +x "$PY_SHIM/python3"
: > "$TMP/py.log"
( cd "$PROJECT_DIR" && PATH="$PY_SHIM:$PATH" HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" )
spawns=$(wc -l < "$TMP/py.log" | tr -d ' ')
ok=1; [ "$spawns" = "1" ] && [ -z "$(git -C "$MEMDIR" status --porcelain)" ] && ok=0
check "an opted-in store costs exactly one python launch per Stop and still commits (got $spawns)" "$ok"

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
