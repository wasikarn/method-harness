#!/usr/bin/env bash
# gauntlet-lock.sh — a per-user queue so only one full gauntlet runs at a time (GH #158).
# The gauntlet's timing rows (finishes inside 4 s / 8 s) fail when several gauntlets, or a gauntlet
# and busy peer sessions, share the machine; waiting for your turn is deterministic where waiting
# for the load to drop is a guess. Source it, then:
#   gauntlet_lock_acquire; trap gauntlet_lock_release EXIT
# The lock is a directory taken with an atomic mkdir, holding the owner's pid. Waiters poll with
# jitter so peers do not all start the moment it frees. A lock whose owner is gone, or that is older
# than GAUNTLET_LOCK_MAX_AGE (pid reuse), is reclaimed by one waiter at a time: it takes a claim dir
# (<lock>.reclaim, atomic mkdir), re-checks that the lock is still stale under the claim, then
# removes it, so no waiter can remove a lock another waiter has just taken. A child of the holder (a
# test that runs the pre-push hook with MH_PREPUSH_FULL=1, or a gauntlet started under it) sees MH_GAUNTLET_LOCK_OWNER and skips the queue, so it cannot
# deadlock the gauntlet that runs it.
# Fail open, and never fail the caller: a wait past GAUNTLET_LOCK_WAIT_SECS, or a lock dir that
# cannot be created, prints a message and runs without the lock. Every command here is guarded, so
# a caller under `set -e` (the pre-push hook) is never aborted by it. This only orders work; it is
# never a gate. Known edge: a pid reused by an unrelated long-lived process keeps a dead owner's
# lock "alive" until GAUNTLET_LOCK_MAX_AGE, so pushes in that hour wait out the cap, then run.
# Env: GAUNTLET_LOCK_DIR (default $HOME/.cache/mh/gauntlet.lock), GAUNTLET_LOCK_WAIT_SECS (1800),
# GAUNTLET_LOCK_POLL (5, seconds, stretched by 0-50% jitter), GAUNTLET_LOCK_MAX_AGE (3600),
# GAUNTLET_LOCK_NOPID_SECS (60: how old a pid-less lock dir must be to count as a crash leftover).
# Bash 3.2.

GAUNTLET_LOCK_HELD=0

_gl_dir() { printf '%s' "${GAUNTLET_LOCK_DIR:-$HOME/.cache/mh/gauntlet.lock}"; }

_gl_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# A numeric env setting, or its default when unset or not a whole number: a typo such as "1h" must
# not make a `[ -lt ]` test error out (that read as "stale" and let a waiter take a live lock).
_gl_num() {
  case "${1:-}" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}

# Seconds since the lock dir last changed (GNU stat first: BSD stat has no -c).
_gl_age() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || { echo 0; return 0; }
  echo $(( $(date +%s) - m ))
}

# 0 when the lock at $1 can be reclaimed.
_gl_stale() {
  local d=$1 owner age
  owner=$(cat "$d/pid" 2>/dev/null || true)
  age=$(_gl_age "$d")
  if [ -n "$owner" ]; then
    _gl_alive "$owner" && [ "$age" -lt "$(_gl_num "${GAUNTLET_LOCK_MAX_AGE:-}" 3600)" ] && return 1
    return 0
  fi
  [ "$age" -ge "$(_gl_num "${GAUNTLET_LOCK_NOPID_SECS:-}" 60)" ]
}

# Remove a lock dir with whatever is in it (only a pid file belongs there). Never fails.
_gl_rmlock() {
  rm -f "$1"/* "$1"/.[!.]* 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
  return 0
}

# Take the lock at $1: an atomic mkdir, then record this process as the owner.
_gl_take() {
  mkdir "$1" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$1/pid" 2>/dev/null || { _gl_rmlock "$1"; return 1; }
  GAUNTLET_LOCK_HELD=1
  export MH_GAUNTLET_LOCK_OWNER=$$
  return 0
}

# Reclaim the stale lock at $1 if this process wins the claim. Returns 0 only when the lock dir is
# gone; one that cannot be emptied (a subdirectory, a read-only dir) returns 1 so the caller still
# sleeps and reaches the wait cap instead of spinning.
_gl_reclaim() {
  local d=$1
  if mkdir "$d.reclaim" 2>/dev/null; then
    if _gl_stale "$d"; then
      _gl_rmlock "$d"
      rmdir "$d.reclaim" 2>/dev/null || true
      [ ! -d "$d" ]
      return
    fi
    rmdir "$d.reclaim" 2>/dev/null || true
    return 1
  fi
  # Another waiter holds the claim; if its process died mid-reclaim the claim dir would block
  # reclaiming for good, so drop one that is old.
  if [ -d "$d.reclaim" ] && [ "$(_gl_age "$d.reclaim")" -ge 60 ]; then
    rmdir "$d.reclaim" 2>/dev/null || true
  fi
  return 1
}

gauntlet_lock_acquire() {
  local d max poll start owner announced=0 nap
  d=$(_gl_dir)
  max=$(_gl_num "${GAUNTLET_LOCK_WAIT_SECS:-}" 1800)
  poll="${GAUNTLET_LOCK_POLL:-5}"

  if [ -n "${MH_GAUNTLET_LOCK_OWNER:-}" ] && _gl_alive "$MH_GAUNTLET_LOCK_OWNER" \
    && [ "$(cat "$d/pid" 2>/dev/null)" = "$MH_GAUNTLET_LOCK_OWNER" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$d")" 2>/dev/null || {
    echo "gauntlet-lock: cannot create $(dirname "$d"); running without the lock" >&2
    return 0
  }

  start=$(date +%s)
  while :; do
    _gl_take "$d" && return 0
    if [ ! -d "$d" ]; then
      # No lock dir to wait on: it was released just now, or it cannot be created (read-only
      # parent, full disk). One more try tells the two apart; do not wait out the cap for the latter.
      _gl_take "$d" && return 0
      if [ ! -d "$d" ]; then
        echo "gauntlet-lock: cannot create $d; running without the lock" >&2
        return 0
      fi
    fi
    if _gl_stale "$d" && _gl_reclaim "$d"; then
      continue
    fi
    if [ "$announced" -eq 0 ]; then
      owner=$(cat "$d/pid" 2>/dev/null || true)
      echo "gauntlet-lock: another gauntlet (pid ${owner:-unknown}) is running; waiting up to ${max}s for my turn" >&2
      announced=1
    fi
    if [ $(( $(date +%s) - start )) -ge "$max" ]; then
      echo "gauntlet-lock: waited ${max}s for the gauntlet lock at $d; running without the lock (timing rows may flake under load, GH #158)" >&2
      return 0
    fi
    # LC_ALL=C: a decimal-comma locale makes awk print "5,85", which sleep rejects.
    nap=$(LC_ALL=C awk -v p="$poll" -v r="$RANDOM" 'BEGIN { printf "%.2f", p * (1 + (r % 50) / 100) }' 2>/dev/null || true)
    sleep "${nap:-5}" 2>/dev/null || sleep 1 || true
  done
}

gauntlet_lock_release() {
  [ "$GAUNTLET_LOCK_HELD" = 1 ] || return 0
  local d
  d=$(_gl_dir)
  if [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ]; then
    _gl_rmlock "$d"
  fi
  GAUNTLET_LOCK_HELD=0
  return 0
}
