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

# gauntlet_pass_start: HEAD's tree when the cwd is the top of a clean checkout, else nothing. A copy that
# is not a repo (a git-archive extract in an ignored dir) would otherwise key on the enclosing checkout.
# --untracked-files=normal: status.showUntrackedFiles=no must not hide an untracked file.
gauntlet_pass_start() {
  local dirty top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0  # not a git checkout: nothing to key on
  [ "$(cd "$top" && pwd -P)" = "$(pwd -P)" ] || return 0
  dirty=$(git status --porcelain --untracked-files=normal) || return 0
  [ -z "$dirty" ] || return 0
  git rev-parse -q --verify 'HEAD^{tree}' || return 0  # no commit yet: nothing to key on
}

# gauntlet_pass_has <tree>: true when the cache is on and a pass is recorded for <tree>.
gauntlet_pass_has() { [ "${GAUNTLET_PASS_CACHE:-1}" != 0 ] && [ -f "$(gauntlet_pass_dir)/$1" ]; }

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

# gauntlet_time_num <value>: the value when it is a whole number with no leading zero, else null (JSON).
gauntlet_time_num() { if [[ "${1-}" =~ ^(0|[1-9][0-9]*)$ ]]; then printf '%s' "$1"; else printf null; fi; }

# gauntlet_time_row <who> <tree> <cached> <gauntlet lock wait> <run secs> <rc> [<timeout>]: append one
# JSON row to GAUNTLET_TIME_LOG (default $HOME/.cache/mh/gauntlet-time.jsonl), so a merge's time splits
# into merge-lock wait, load wait, gauntlet-lock wait and the run. merge-pr.sh sets the plain shell vars
# GAUNTLET_TIME_MERGE_LOCK_WAIT, GAUNTLET_TIME_LOAD_WAIT and GAUNTLET_TIME_ROUND (null when unset, as on a
# sync-pr-head.sh run). An empty tree or timeout is null; <cached> is true, false or null; a field that is
# not a whole number is null. The only writer of the log. A relative log path or a write that fails
# prints a note and writes nothing; returns 0 either way.
gauntlet_time_row() {
  # ${HOME:+...}: no HOME under the callers' set -u gives an empty path (the note below), not an abort.
  local log="${GAUNTLET_TIME_LOG:-${HOME:+$HOME/.cache/mh/gauntlet-time.jsonl}}" tree=null timeout=null
  # A relative path would land in the checkout the gauntlet ran on, and merge-pr.sh refuses a changed one.
  # shortcut: an absolute path inside the checkout is not caught; keep the log outside any checkout.
  case "$log" in
    /*) ;;
    *) echo "$1: GAUNTLET_TIME_LOG must be an absolute path (got $log); no timing row written." >&2; return 0 ;;
  esac
  [ -z "$2" ] || tree="\"$2\""
  [ -z "${7-}" ] || timeout="\"$7\""
  mkdir -p "$(dirname "$log")" && printf '{"time":"%s","who":"%s","tree":%s,"cached":%s,"gauntlet_lock_wait":%s,"run_secs":%s,"rc":%s,"merge_lock_wait":%s,"load_wait":%s,"round":%s,"timeout":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$tree" "$3" "$(gauntlet_time_num "$4")" "$(gauntlet_time_num "$5")" \
    "$(gauntlet_time_num "$6")" "$(gauntlet_time_num "${GAUNTLET_TIME_MERGE_LOCK_WAIT-}")" \
    "$(gauntlet_time_num "${GAUNTLET_TIME_LOAD_WAIT-}")" "$(gauntlet_time_num "${GAUNTLET_TIME_ROUND-}")" "$timeout" >>"$log" ||
    echo "$1: could not append the timing row to $log" >&2
  return 0
}

# gauntlet_full <who>: from the root of a clean checkout, run its own scripts/run-gauntlet.sh under the
# gauntlet lock (GH #158), unless this tree already passed. All output goes to stderr. Returns the
# gauntlet's status. The lock is taken in a subshell: callers that hold another lock built on the same
# library (merge-pr.sh's merge lock) share GAUNTLET_LOCK_HELD and MH_GAUNTLET_LOCK_OWNER with it.
# Each call, cached or run, appends one gauntlet_time_row; a run stopped by INT/TERM/HUP writes none.
gauntlet_full() {
  local who=$1 tree d
  tree=$(git rev-parse --verify 'HEAD^{tree}') || return 1
  d=$(gauntlet_pass_dir)
  if gauntlet_pass_has "$tree"; then
    echo "$who: the full gauntlet already passed on tree $tree ($d/$tree); skipping it (GAUNTLET_PASS_CACHE=0 runs it anyway)." >&2
    gauntlet_time_row "$who" "$tree" true null null null
    return 0
  fi
  echo "$who: running the full gauntlet on $(git rev-parse HEAD)..." >&2
  (
    # Unsharded: a leftover GAUNTLET_SHARD=i/N would make a partial run pass for the whole tree.
    unset MH_GAUNTLET_LOCK_OWNER GAUNTLET_SHARD
    # shellcheck disable=SC2034 # read by gauntlet_lock_release
    GAUNTLET_LOCK_HELD=0
    t0=$SECONDS
    gauntlet_lock_acquire
    t1=$SECONDS
    trap gauntlet_lock_release EXIT
    trap 'exit 130' INT TERM HUP
    # GH #814: these callers run in the background with no terminal, so progress is on unless the caller set it.
    rc=0
    GAUNTLET_PROGRESS="${GAUNTLET_PROGRESS:-1}" bash "$(git rev-parse --show-toplevel)/scripts/run-gauntlet.sh" >&2 || rc=$?
    gauntlet_time_row "$who" "$tree" false "$((t1 - t0))" "$((SECONDS - t1))" "$rc"
    exit "$rc"
  )
}

# gauntlet_status_post <who> <sha>: after a green or cached gauntlet on <sha>, and once origin has <sha>,
# post the GitHub commit status mh/gauntlet=success on it (GH #742), so branch protection can require it.
# Needs gh: without it nothing posts the status, so once branch protection requires mh/gauntlet a cloud
# MCP-only merge is refused; merge from a machine with gh then.
# Any token with repo scope can post one: an honest-agent gate, not a security boundary.
gauntlet_status_post() {
  local who=$1 sha=$2 tree
  tree=$(git rev-parse --verify "$sha^{tree}") || return 1
  gh api --method POST "repos/{owner}/{repo}/statuses/$sha" -f state=success -f context=mh/gauntlet \
    -f "description=full gauntlet passed on tree $tree" >/dev/null ||
    { echo "$who: could not post the mh/gauntlet status on $sha; stopping before any merge." >&2; return 1; }
}
