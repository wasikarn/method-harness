#!/usr/bin/env bash
# Stop: commit any dirty changes in the current project's memory store to its
# own git history. Restores a real audit trail / rollback path for the
# memory store, which previously had zero version control — see
# docs/research/agent-memory-engineering-2026-08-07.md proposal A4 (verified
# 2026-08-07: `git rev-parse --is-inside-work-tree` failed against the live
# store, confirmed, not assumed).
#
# Fires on Stop (per-turn, not once-per-session) — deliberately more
# frequent than a true "session boundary". `git add`+`commit` is cheap and a
# no-op when the tree is clean, so the extra granularity is a feature (finer
# rollback resolution), not a cost worth avoiding. Mirrors
# hooks/stop/cost-tracker.sh's own async:true wiring so a slow or failing
# git call never blocks turn completion.
#
# Requires the memory dir to ALREADY be a git repo (one-time, user-run
# `git init`) — this hook never runs `git init` itself. Initializing version
# control on a directory outside this repo is a decision the user makes
# once, not something a Stop hook does silently on their real data.
#
# Cross-session locking (2026-09-28, worktree-per-session support): the
# memory store is now reachable identically from every worktree of a repo
# (scripts/_lib/memory-dir.py), so two sessions ending at the same instant
# race for real -- `.git/index.lock` contention, or one session's marker
# overwritten by another's. Serialized via an atomic mkdir lock directory
# (portable; `flock` is not reliably available on macOS). See ACQUIRE_LOCK
# below for the full protocol and its rationale.
set -uo pipefail

# Unset/relative HOME: skip silently, same guard as hooks/stop/cost-tracker.sh
# (M8) -- under set -u an unset HOME used to crash this hook on the line below.
if [ -z "${HOME:-}" ] || [[ "$HOME" != /* ]]; then
  exit 0
fi

command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

_MEMDIR_RESOLVER="${CLAUDE_PLUGIN_ROOT:-}/scripts/_lib/memory-dir.py"
[ -r "$_MEMDIR_RESOLVER" ] || exit 0
# One python launch for memory dir, enc and ACQUIRE_TS (was three): NUL-separated,
# loaded by path under -I like hooks/session/memory-health-nudge.sh.
# Sub-second ACQUIRE_TS matters: two events (a retry after a quick failure, a
# genuinely concurrent waiter and holder) can land in the same wall-clock
# second under `date +%s`, which would break the "strictly older" ordering
# the marker sweep below depends on (BSD `date` has no %N).
MEMDIR="" ENC="" ACQUIRE_TS=""
{
  IFS= read -r -d '' MEMDIR
  IFS= read -r -d '' ENC
  IFS= read -r -d '' ACQUIRE_TS
} < <(python3 -I -c '
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("memory_dir", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.stdout.write(m.resolve_memory_dir() + "\0" + m.resolve_enc() + "\0" + repr(time.time()) + "\0")
' "$_MEMDIR_RESOLVER" 2>/dev/null)
[ -n "$MEMDIR" ] || exit 0

[ -d "$MEMDIR/.git" ] || exit 0   # not opted in — nothing to do

[ -n "$ENC" ] || exit 0
[ -n "$ACQUIRE_TS" ] || ACQUIRE_TS="$(date +%s)"

mkdir -p "$HOME/.claude/state" 2>/dev/null

# Per-attempt marker (PID-suffixed, not one shared $FAILMARKER): a single
# shared marker let one session's own successful cleanup silently erase a
# DIFFERENT, still-in-flight session's diagnostic. Line 1 is a machine-read
# "acquisition_ts=<epoch>" record (see the success-path sweep below); the
# rest is the human-readable diagnostic. $$ is a fresh PID on every
# invocation, so nothing but the timestamp-ordering sweep below can ever
# reliably retire an old one — see ACQUIRE_LOCK's cleanup comment.
MYMARKER="$HOME/.claude/state/memory-audit-commit-fail-$ENC-$$"
write_marker() {
  { printf 'acquisition_ts=%s\n' "$ACQUIRE_TS"; printf '%s\n' "$1"; } > "$MYMARKER" 2>/dev/null
}

LOCKDIR="$HOME/.claude/state/memory-audit-commit-lock-$ENC"
LOCK_WAIT_MAX="${MH_MEMORY_LOCK_WAIT_MAX:-10}"                  # seconds, bounded wait before giving up
LOCK_POLL_INTERVAL="${MH_MEMORY_LOCK_POLL_INTERVAL:-0.2}"
LOCK_STALE_METADATA_SEC="${MH_MEMORY_LOCK_STALE_METADATA_SEC:-300}"  # only for corrupted/unreadable lock metadata

# Read this process's own start time once, for the lock-ownership record.
# `ps -o lstart=` is available on both macOS and Linux; used to detect PID
# reuse below (a bare PID can be recycled by the OS after its owner exits).
_my_start="$(ps -o lstart= -p $$ 2>/dev/null)"

_holder_is_alive() {
  # $1 = PID recorded in the lock, $2 = start-time recorded in the lock.
  # Returns 0 (alive, do NOT reclaim) only when a process with that PID
  # exists AND its current start time matches the recorded one -- a mismatch
  # means the PID was reused by an unrelated process, i.e. the original
  # holder is actually gone.
  local pid="$1" recorded_start="$2" current_start
  kill -0 "$pid" 2>/dev/null || return 1
  current_start="$(ps -o lstart= -p "$pid" 2>/dev/null)"
  [ -n "$current_start" ] && [ "$current_start" = "$recorded_start" ]
}

_try_reclaim_stale_lock() {
  # Reclaim only on a POSITIVE confirmation the original owner is gone:
  # missing/unreadable metadata past a conservative age (corrupted lock), or
  # a PID that's dead or was reused. Never reclaims a live, identity-
  # confirmed holder just because it's been running a while -- a real git
  # commit can legitimately take longer than any fixed threshold on a large
  # repo or a loaded disk.
  local pidfile="$LOCKDIR/pid" startfile="$LOCKDIR/start" pid start
  if [ ! -r "$pidfile" ] || [ ! -r "$startfile" ]; then
    # Corrupted/incomplete lock metadata -- only reclaim once it's old
    # enough that a normal acquire-then-populate race is implausible.
    local age
    age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR" 2>/dev/null || stat -c%Y "$LOCKDIR" 2>/dev/null || echo 0) ))
    if [ "$age" -ge "$LOCK_STALE_METADATA_SEC" ]; then
      rmdir "$LOCKDIR" 2>/dev/null || rm -rf "$LOCKDIR" 2>/dev/null
      return 0
    fi
    return 1
  fi
  pid="$(cat "$pidfile" 2>/dev/null)"
  start="$(cat "$startfile" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  if _holder_is_alive "$pid" "$start"; then
    return 1   # live, identity-confirmed holder -- never reclaim
  fi
  rm -rf "$LOCKDIR" 2>/dev/null
  return 0
}

LOCK_HELD=0
_release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -rf "$LOCKDIR" 2>/dev/null
    LOCK_HELD=0
  fi
}
trap _release_lock EXIT INT TERM

_waited=0
while true; do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null
    printf '%s\n' "$_my_start" > "$LOCKDIR/start" 2>/dev/null
    LOCK_HELD=1
    break
  fi
  _try_reclaim_stale_lock && continue
  awk -v w="$_waited" -v m="$LOCK_WAIT_MAX" 'BEGIN{exit !(w>=m)}' && {
    write_marker "lock wait timed out after ${LOCK_WAIT_MAX}s (another session held $LOCKDIR) -- this session's memory changes were not committed this turn; will retry next Stop."
    exit 0
  }
  sleep "$LOCK_POLL_INTERVAL"
  _waited=$(awk -v w="$_waited" -v i="$LOCK_POLL_INTERVAL" 'BEGIN{print w+i}')
done

# --- Everything below runs with the lock held; _release_lock (trap) frees
# it on any exit path, normal or signaled. ---

# Dirty check first (cheap) — skip the add/commit round-trip when clean.
# One `git status --porcelain` covers unstaged, staged, and untracked in a
# single call (same three states the old diff/diff-cached/ls-files trio
# checked separately). -unormal pins untracked-file reporting on regardless
# of any status.showUntrackedFiles=no set globally or in this repo — the old
# `ls-files --others` path always reported untracked files, so silently
# deferring to that config here would turn this hook into a no-op for new
# memory files on a machine with that setting.
#
# Scoped to '*.md' rather than '.' (repo convention is "stage by explicit
# name, never -A") — this directory's entire designed content is memory .md
# files the assistant writes, so the glob covers everything the hook is
# meant to commit (verified: git's glob pathspec recurses into subdirs like
# _archive/, and also stages deletions of tracked .md files, not just adds).
# A non-.md file dropped here by hand for the user's own reference is never
# swept in.
_dirty=1
if [ -z "$(git -C "$MEMDIR" status --porcelain -unormal -- '*.md' 2>/dev/null)" ]; then
  _dirty=0
fi

if [ "$_dirty" -eq 1 ]; then
  # H6 (harness gap-audit, 2026-09-20): both git calls used to redirect
  # stderr and never check an exit code -- any commit precondition failing
  # (missing user.name, GPG signing unavailable) silently stopped
  # versioning the memory store forever, with no signal until someone
  # happened to check by hand. Now writes a per-attempt marker
  # memory-health-nudge.sh surfaces at next SessionStart.
  ADD_ERR=$(git -C "$MEMDIR" add -- '*.md' 2>&1)
  ADD_RC=$?
  if [ "$ADD_RC" -ne 0 ]; then
    write_marker "git add failed (exit $ADD_RC): $ADD_ERR"
    exit 0
  fi

  COMMIT_ERR=$(git -C "$MEMDIR" commit -m "auto-snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --quiet 2>&1)
  COMMIT_RC=$?
  if [ "$COMMIT_RC" -ne 0 ]; then
    write_marker "git commit failed (exit $COMMIT_RC): $COMMIT_ERR"
    exit 0
  fi
fi

# Success (clean tree, or a commit just landed): sweep every marker
# strictly older than THIS attempt's own acquisition time -- a
# provably-superseded failure from before this attempt even started. Never
# touches a marker timestamped at or after this attempt's own acquisition,
# which is exactly what protects a concurrent waiter's still-in-flight
# diagnostic (it falls inside or after this attempt's held-lock window) --
# ordering alone does it, with no separate identity check needed. Never
# touches this attempt's own $MYMARKER by name (there isn't one on the
# success path, since it's only written on a failure/timeout above).
shopt -s nullglob
for _m in "$HOME"/.claude/state/memory-audit-commit-fail-"$ENC"-*; do
  # The glob also matches a longer ENC's markers (proj vs proj-v2); only a
  # pure-digit tail (the pid) is this store's. Same acceptance as the nudge.
  [[ "${_m##*/memory-audit-commit-fail-"$ENC"-}" =~ ^[0-9]+$ ]] || continue
  _ts_line="$(head -1 "$_m" 2>/dev/null)"
  _ts="${_ts_line#acquisition_ts=}"
  if [[ "$_ts" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
     && awk -v a="$_ts" -v b="$ACQUIRE_TS" 'BEGIN{exit !(a<b)}'; then
    rm -f "$_m" 2>/dev/null
  fi
done
shopt -u nullglob

exit 0
