#!/usr/bin/env bash
# replay-check.sh (GH #891): which replay-supported gates a tree changes against a base with no whole-pool
# replay record for the new closure (scripts/_lib/gate_closure.py: the gate's .sh and .py, _run.py and the
# shared _*.py, _*.sh and *.awk files it uses). scripts/gate-differential.sh --replay all writes the record. Sourced by
# merge-pr.sh, which refuses before the gauntlet and the merge, and by sync-pr-head.sh, which refuses before
# it posts mh/gauntlet: branch protection lets an MCP merge through on that status, so without this check a
# cloud session could merge a gate change with no replay. Diffs in a record do not refuse: the record proves
# the replay ran, and its counts are printed for the operator to explain on the PR. Bash 3.2.

REPLAY_GATES="irrecoverable subagent-git-guard secret-scan"
REPLAY_CHECK_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
replay_dir() { printf '%s' "${GATE_REPLAY_RECORD_DIR:-$HOME/.cache/mh/gate-replay}"; }
# replay_hint <base> <gate>: the command that writes the gate's record.
replay_hint() { printf 'bash scripts/gate-differential.sh %s %s --replay all --no-cache' "$1" "$2"; }

# closure_of <rev> <gate>: runs at the checkout's top. gate_closure.py --rev reads from the repo top itself
# (--full-tree); the cd is a second guard, since from a subdir an older copy hashed nothing.
closure_of() {
  local top
  top=$(git rev-parse --show-toplevel) || return 1
  (cd "$top" && python3 "$REPLAY_CHECK_LIB/gate_closure.py" --rev "$1" "$2")
}

# replay_missing <who> <rev> <base>: prints "<gate>:<closure>", one per line, for each gate whose closure
# at <rev> differs from <base>'s with no record for it; prints each accepted record's counts on stderr.
# Returns 1, after a message, when a closure cannot be computed.
replay_missing() {
  local who=$1 rev=$2 base=$3 g c d rec
  for g in $REPLAY_GATES; do
    c=$(closure_of "$rev" "$g") || { echo "$who: cannot compute the $g gate's closure at $rev." >&2; return 1; }
    d=$(closure_of "$base" "$g") || { echo "$who: cannot compute the $g gate's closure at $base." >&2; return 1; }
    [ "$c" != "$d" ] || continue
    rec="$(replay_dir)/$g-$c.json"
    # A record that jq cannot read prints jq's error and counts as no record.
    # GH #958: the two command gates also judge Monitor and ctx_* tools; a record without "shapes": 2 never replayed those.
    if [ -f "$rec" ] && jq -e --arg g "$g" --arg c "$c" '.gate == $g and .closure == $c and .full == true and .cache == false and ($g == "secret-scan" or (.shapes // 0) >= 2)' "$rec" >/dev/null; then
      jq -r --arg w "$who" '"\($w): replay record for \(.gate) (closure \(.closure[0:12]), \(.time)): pool \(.pool), replayed \(.replay), corpus \(.corpus), \(.diffs) diffs, \(.slower) slower; explain any diff or slower command on the PR."' "$rec" >&2
      continue
    fi
    printf '%s:%s\n' "$g" "$c"
  done
}
