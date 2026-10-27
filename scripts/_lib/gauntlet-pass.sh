#!/usr/bin/env bash
# gauntlet-pass.sh — the gauntlet's pass cache and the full run made before a merge push (GH #735).
# A push runs only a fast lint (git-hooks/pre-push); scripts/merge-pr.sh and scripts/sync-pr-head.sh run
# the full gauntlet themselves, through gauntlet_full, on the exact tree they push and merge.
# A pass is an empty-ish file named by the tree hash. scripts/run-gauntlet.sh records one only after a
# full run (no GAUNTLET_SHARD) where every layer passed, on a checkout identical to HEAD (git status
# --porcelain empty, untracked files count) at the start and at the end. gauntlet_full skips the run on
# a hit, so a rerun on the same tree costs nothing.
# Source gauntlet-lock.sh first. Env: GAUNTLET_PASS_DIR (default $HOME/.cache/mh/gauntlet-pass);
# GAUNTLET_PASS_CACHE=0 neither reads nor writes the cache (forces a run). Bash 3.2.

gauntlet_pass_dir() { printf '%s' "${GAUNTLET_PASS_DIR:-$HOME/.cache/mh/gauntlet-pass}"; }

# gauntlet_pass_start: HEAD's tree when the checkout in the cwd is clean, else nothing.
gauntlet_pass_start() {
  local dirty
  dirty=$(git status --porcelain 2>/dev/null) || return 0  # not a git checkout: nothing to key on
  [ -z "$dirty" ] || return 0
  git rev-parse -q --verify 'HEAD^{tree}' || true
  return 0
}

# gauntlet_pass_record <fail> <shard> <tree at start>: record a pass for the cwd's tree when the run
# passed (fail 0), was not a shard, started clean (tree given) and is still clean on that same tree.
# Never fails the caller; a write that fails says so on stderr.
gauntlet_pass_record() {
  local fail=$1 shard=$2 start=$3 now d
  [ "${GAUNTLET_PASS_CACHE:-1}" != 0 ] && [ "$fail" = 0 ] && [ -z "$shard" ] && [ -n "$start" ] || return 0
  now=$(gauntlet_pass_start)
  [ "$now" = "$start" ] || return 0
  d=$(gauntlet_pass_dir)
  if mkdir -p "$d" && date -u +%Y-%m-%dT%H:%M:%SZ >"$d/$now"; then
    echo "gauntlet: pass recorded for tree $now"
  else
    echo "gauntlet: could not record the pass in $d" >&2
  fi
  return 0
}

# gauntlet_full <who>: from the root of a clean checkout, run its own scripts/run-gauntlet.sh under the
# gauntlet lock (GH #158), unless this tree already passed. All output goes to stderr. Returns the
# gauntlet's status. The lock is taken in a subshell: callers that hold another lock built on the same
# library (merge-pr.sh's merge lock) share GAUNTLET_LOCK_HELD and MH_GAUNTLET_LOCK_OWNER with it.
gauntlet_full() {
  local who=$1 tree d
  tree=$(git rev-parse --verify 'HEAD^{tree}') || return 1
  d=$(gauntlet_pass_dir)
  if [ "${GAUNTLET_PASS_CACHE:-1}" != 0 ] && [ -f "$d/$tree" ]; then
    echo "$who: the full gauntlet already passed on tree $tree ($d/$tree); skipping it (GAUNTLET_PASS_CACHE=0 runs it anyway)." >&2
    return 0
  fi
  echo "$who: running the full gauntlet on $(git rev-parse HEAD)..." >&2
  (
    unset MH_GAUNTLET_LOCK_OWNER
    # shellcheck disable=SC2034 # read by gauntlet_lock_release
    GAUNTLET_LOCK_HELD=0
    gauntlet_lock_acquire
    trap gauntlet_lock_release EXIT
    trap 'exit 130' INT TERM HUP
    bash "$(git rev-parse --show-toplevel)/scripts/run-gauntlet.sh" >&2
  )
}
