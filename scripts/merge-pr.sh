#!/usr/bin/env bash
# merge-pr.sh <PR> — bring a develop PR up to date, cut its version, push it, and merge it (GH #450).
# PRs do not touch the version. When the PR branch is behind origin/develop the script merges develop
# into it, writes develop's version + 1 into both manifests in the same commit, and pushes, so the
# pre-push gauntlet runs on the exact tree that merges (#445 + #446 were green alone and red
# together). Until 2026-10-25 each PR bumped its own version, and every peer merge re-conflicted every
# open PR on those two lines (#581 took ~6 re-syncs). A per-user lock lets one merge-pr.sh run at a
# time, so develop holds still while a merge's gauntlet runs; a merge made outside the script costs a
# retry round (3 at most). --match-head-commit pins the merge to the pushed sha: a push after the check
# makes GitHub refuse. Checks are local-only; this narrows the race, it does not close it. It also
# refuses a PR with no fresh review verdict (see check_review).
# Run it from the PR's own checkout, on its branch, with a clean tree: it commits there and pushes.
# One run can span a gauntlet plus lock waits (> 10 min), so start it in the background.
# Bash 3.2. Env: MERGE_PR_LOAD_MAX (default 4), MERGE_PR_LOAD_WAIT_SECS (900),
# MERGE_PR_LOCK_DIR ($HOME/.cache/mh/merge-pr.lock), MERGE_PR_LOCK_WAIT_SECS (3600).
#
# merge-pr.sh --verify <PR> <head sha> <base branch> <comments.json> — the same checks without gh, for a
# session that has none (a Claude Code cloud session) and merges through the GitHub MCP tools. The caller
# passes what those tools return: the head sha, the base branch, and the PR's issue comments as a JSON
# array of objects with a "body" (read by the same verdict parser). It runs the base, review, ancestry
# and version checks and never takes the lock, syncs, pushes or merges: a head that lacks origin/develop
# or a version above it is refused with the scripts/sync-pr-head.sh command to run first. On a pass it
# prints the head; merge it pinned to that sha (expectedHeadSha) right away. Before this mode, cloud
# sessions retyped these checks by hand for every merge (#633, #644, #648).
set -euo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/gauntlet-lock.sh
. "$HERE/_lib/gauntlet-lock.sh"

usage() {
  echo "usage: merge-pr.sh <PR number>" >&2
  echo "       merge-pr.sh --verify <PR number> <head sha> <base branch> <comments.json>" >&2
  exit 2
}
verify=0
if [ "${1:-}" = "--verify" ]; then
  verify=1
  pr="${2:-}" head="${3:-}" base="${4:-}" comments_file="${5:-}"
  if [ -z "$pr" ] || [ -z "$head" ] || [ -z "$base" ] || [ -z "$comments_file" ] || [ $# -gt 5 ]; then usage; fi
  if ! [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "merge-pr: --verify needs the full 40-character head sha, not '$head'." >&2
    exit 2
  fi
else
  pr="${1:-}"
  [ -n "$pr" ] || usage
fi

PLUGIN=.claude-plugin/plugin.json
MARKET=.claude-plugin/marketplace.json
die() { echo "merge-pr: $*" >&2; exit 1; }

# On any exit: abort a sync merge this script left open, drop a version edit it left uncommitted, and
# free the merge lock. A failed step therefore leaves the branch as the last commit the script made.
merge_open=0
bump_open=0
cleanup() {
  if [ "$merge_open" = 1 ] && git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git merge --abort || echo "merge-pr: git merge --abort failed; clean up the branch by hand." >&2
  elif [ "$bump_open" = 1 ]; then
    git restore --staged --worktree --source=HEAD -- "$PLUGIN" "$MARKET" ||
      echo "merge-pr: could not restore $PLUGIN and $MARKET; restore them by hand." >&2
  fi
  merge_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# The merge lock is the gauntlet queue's code with its own dir. `local` keeps GAUNTLET_LOCK_DIR out of
# the environment, so the pre-push hook under this script still queues on the gauntlet lock.
merge_lock_dir="${MERGE_PR_LOCK_DIR:-$HOME/.cache/mh/merge-pr.lock}"
merge_lock_take() {
  # shellcheck disable=SC2034 # read by gauntlet_lock_acquire
  # A live run can pass the queue's default 1 h stale age (3 rounds of load wait plus a gauntlet).
  local GAUNTLET_LOCK_DIR="$merge_lock_dir" GAUNTLET_LOCK_WAIT_SECS="${MERGE_PR_LOCK_WAIT_SECS:-3600}" GAUNTLET_LOCK_MAX_AGE=14400
  gauntlet_lock_acquire
}
merge_lock_release() {
  # shellcheck disable=SC2034 # read by gauntlet_lock_release
  local GAUNTLET_LOCK_DIR="$merge_lock_dir"
  gauntlet_lock_release
}

git fetch origin

if [ "$verify" = 0 ]; then
  info=$(gh pr view "$pr" --json headRefOid,baseRefName,headRefName,isCrossRepository \
    -q '.headRefOid + " " + .baseRefName + " " + .headRefName + " " + (.isCrossRepository | tostring)')
  read -r head base branch cross <<<"$info"
  if [ -z "$head" ] || [ -z "${branch:-}" ]; then
    die "could not read the head sha, base and head branch of PR $pr"
  fi
  # The script pushes the sync to origin's $branch; a fork PR's branch is not there.
  if [ "${cross:-}" != "false" ]; then
    die "PR $pr comes from a fork (or gh did not say; isCrossRepository=${cross:-unknown}); the script can only sync and push a branch on origin. Merge it on GitHub."
  fi
fi
if [ "$base" != "develop" ]; then
  echo "merge-pr: PR $pr targets '$base', not develop; the origin/develop check would prove nothing." >&2
  echo "Retarget it (gh pr edit $pr --base develop) or ask the operator; do not fall back to a bare gh pr merge." >&2
  exit 1
fi

# The gauntlet runs on this working tree, so it must be the PR branch with nothing beside the commit.
if [ "$verify" = 0 ]; then
  cur=$(git symbolic-ref --quiet --short HEAD) || cur=""
  if [ "$cur" != "$branch" ]; then
    die "run this from a checkout of PR $pr's branch $branch (this one is on ${cur:-a detached HEAD}): the script commits the sync and the version there and pushes them."
  fi
fi
# require_clean <when>: checked at the start, at each round, and before and after the push, since the
# lock and load waits leave the caller time to edit this checkout.
require_clean() {
  local dirty
  dirty=$(git status --porcelain) || die "git status failed."
  if [ -n "$dirty" ]; then
    die "the checkout has uncommitted or untracked files $1; the pre-push gauntlet runs on this tree, so it must match the commit that merges. Commit or move them, and do not edit this checkout while merge-pr.sh runs."
  fi
}
if [ "$verify" = 0 ]; then
  require_clean "at the start"
  rc=0
  git merge-base --is-ancestor "$head" HEAD || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "local $branch does not contain PR $pr's head $head (rc=$rc); pull the branch first."
  fi
fi

# First "version" key; awk reads all of its input, so no SIGPIPE under pipefail.
first_version() { awk -F'"' '/"version"/ && !seen { print $4; seen = 1 }'; }
manifest_version() {
  local raw
  raw=$(git show "$1:$2") || { echo "merge-pr: cannot read $2 at $1." >&2; exit 1; }
  printf '%s\n' "$raw" | first_version
}
# with_version <version>: copy stdin to stdout with the first "version" value set to <version>.
with_version() {
  awk -v v="$1" '!done && /"version"/ { done = sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" v "\"") } { print }'
}
set_version() {
  local new
  new=$(with_version "$2" <"$1") || die "cannot rewrite the version in $1."
  printf '%s\n' "$new" >"$1"
}
is_xyz() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
# version_lt A B: exit 0 when dotted version A is lower than B.
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

# A PR made before the version moved here still bumps its own version, and merging develop conflicts on
# that line alone. Merge each conflicted manifest again with the version set to one placeholder on all
# three sides, so the PR's other edits in the file survive, then put the PR's own version back, so
# sync_and_bump keeps a deliberate higher one (a minor bump) and cuts develop + 1 otherwise.
# Any other conflict refuses.
placeholder_blob() { git show ":$1:$2" | with_version 0.0.0-merge | git hash-object -w --stdin; }
resolve_manifest_conflicts() {
  local files f b o t merged ours mrc
  files=$(git diff --name-only --diff-filter=U) || die "cannot list the conflicted files."
  [ -n "$files" ] || die "git merge origin/develop failed without a conflict (see above)."
  while IFS= read -r f; do
    case "$f" in
      "$PLUGIN" | "$MARKET") ;;
      *) die "merging origin/develop into $branch conflicts in $f, not only on the version. Merge origin/develop by hand, commit, push, then run merge-pr.sh again." ;;
    esac
  done <<<"$files"
  while IFS= read -r f; do
    { b=$(placeholder_blob 1 "$f") && o=$(placeholder_blob 2 "$f") && t=$(placeholder_blob 3 "$f"); } ||
      die "cannot read the merge stages of $f."
    mrc=0
    merged=$(git merge-file -p --object-id "$o" "$b" "$t") || mrc=$?
    # merge-file exits with the conflict count, or 128+ on an error (--object-id needs git 2.43+).
    [ "$mrc" -lt 128 ] || die "git merge-file failed on $f (rc=$mrc; it needs git 2.43 or later)."
    [ "$mrc" -eq 0 ] ||
      die "$f still conflicts with the version set aside (another edit in it clashes). Merge origin/develop by hand, commit, push, then run merge-pr.sh again."
    ours=$(git show ":2:$f" | first_version) || die "cannot read the PR's version of $f."
    if is_xyz "$ours"; then
      merged=$(printf '%s\n' "$merged" | with_version "$ours") || die "cannot rewrite the version in $f."
    fi
    printf '%s\n' "$merged" >"$f"
    git add -- "$f"
    echo "merge-pr: $f conflicted only on the version; merged the rest." >&2
  done <<<"$files"
}

# sync_and_bump: merge origin/develop into the checkout when it is behind, then write develop's
# version + 1 into both manifests unless they already agree on a higher one, and commit what changed.
sync_and_bump() {
  local dev_ver cur_ver mkt_ver new="" merging=0 rc=0
  git merge-base --is-ancestor origin/develop HEAD || rc=$?
  if [ "$rc" -eq 1 ]; then
    merging=1
    merge_open=1
    git merge --no-commit --no-ff origin/develop || resolve_manifest_conflicts
  elif [ "$rc" -ne 0 ]; then
    die "ancestry check against origin/develop failed (rc=$rc); is origin/develop fetched?"
  fi
  dev_ver=$(manifest_version origin/develop "$PLUGIN")
  is_xyz "$dev_ver" || die "origin/develop's version '$dev_ver' is not X.Y.Z; cannot cut the next one."
  cur_ver=$(first_version <"$PLUGIN")
  mkt_ver=$(first_version <"$MARKET")
  if [ "$cur_ver" != "$mkt_ver" ] || ! is_xyz "$cur_ver" || ! version_lt "$dev_ver" "$cur_ver"; then
    new=$(awk -F. '{ print $1 "." $2 "." $3 + 1 }' <<<"$dev_ver")
    bump_open=1
    set_version "$PLUGIN" "$new"
    set_version "$MARKET" "$new"
    git add -- "$PLUGIN" "$MARKET"
  fi
  if [ "$merging" -eq 1 ]; then
    git commit -q -m "Merge origin/develop into $branch${new:+; bump mh to $new}" || die "git commit of the sync failed (see above)."
  elif [ -n "$new" ]; then
    git commit -q -m "chore: bump mh to $new" -- "$PLUGIN" "$MARKET" || die "git commit of the version bump failed (see above)."
  fi
  merge_open=0
  bump_open=0
}

# The last word on the version, run on the head about to be pushed and again before the merge: both
# manifests agree on a plain X.Y.Z above origin/develop's. An identical bump rebases away with no
# conflict, so two PRs once cut one number (#492/#493, #496/#497); sync_and_bump should make every
# refusal here unreachable.
resync_hint() {
  if [ "$verify" = 1 ]; then
    echo "run scripts/sync-pr-head.sh <head branch> $head, then --verify the sha it prints"
  else
    echo "run merge-pr.sh again so it cuts the next number"
  fi
}
check_version() {
  local head_ver mkt_ver dev_ver v
  head_ver=$(manifest_version "$head" "$PLUGIN")
  mkt_ver=$(manifest_version "$head" "$MARKET")
  dev_ver=$(manifest_version origin/develop "$PLUGIN")
  if [ -z "$head_ver" ] || [ -z "$mkt_ver" ] || [ -z "$dev_ver" ]; then
    echo "merge-pr: could not read the manifest version of the PR head or origin/develop." >&2
    exit 1
  fi
  for v in "$head_ver" "$mkt_ver" "$dev_ver"; do
    if ! is_xyz "$v"; then
      echo "merge-pr: manifest version '$v' is not X.Y.Z; cannot order it against origin/develop." >&2
      exit 1
    fi
  done
  if [ "$head_ver" != "$mkt_ver" ]; then
    echo "merge-pr: PR $pr head has plugin.json $head_ver but marketplace.json $mkt_ver; the two manifests must agree." >&2
    exit 1
  fi
  if ! version_lt "$dev_ver" "$head_ver"; then
    echo "merge-pr: PR $pr head ships version $head_ver, not above origin/develop's $dev_ver; $(resync_hint)." >&2
    exit 1
  fi
}
# Refuse a PR with no current review verdict. On 2026-10-25 #569–#576 and #611 merged while their reviews
# still said FIX FIRST, and #570 opened a hole (`env -S -i rm -rf build` allowed) that took #602 to close.
# The verdict is a line "Fresh-context review: MERGE @ <sha>" (or FIX FIRST / CLOSE) in a PR comment,
# <sha> being the head the reviewer read. The last verdict on the PR must be MERGE, and every commit after
# <sha> must be a merge of develop or touch only the two manifests (a version bump): a sync before the merge
# keeps the review, any other change needs a new one. Binding to the sha, not to times, means a commit made
# before the review but pushed after it, or a backdated one, is still caught. A line inside a ``` fence does
# not count, and the last verdict line in a comment wins. Only issue comments are read (not PR reviews or the
# body). This proves a verdict was posted, not who wrote it or that the reviewer had fresh context (CLAUDE.md
# asks for that), and a conflict resolved inside a merge commit is not checked. There is no opt-out: an
# operator who must merge without a verdict does it on GitHub.
REVIEW_JQ='.[] | (.body | split("\n") | reduce .[] as $l ({f: false, m: null};
    if ($l | test("^\\s*(```|~~~)")) then .f = (.f | not)
    elif .f then .
    else ((($l | capture("^[#*\\s]*fresh-context review\\s*:\\s*\\**\\s*(?<v>MERGE|FIX FIRST|CLOSE)\\b(?<r>.*)$"; "i")) as $c | .m = $c) // .)
    end) | .m) as $m
  | select($m != null)
  | "\($m.v | ascii_upcase | gsub(" "; "_")) \(($m.r | capture("^[*\\s]*@\\s*`?(?<s>[0-9a-fA-F]{7,40})\\b") | .s) // "-")"'
check_review() {
  local verdicts last word sha revs c files
  if [ "$verify" = 1 ]; then
    verdicts=$(jq -r "$REVIEW_JQ" <"$comments_file") ||
      { echo "merge-pr: could not read PR $pr's comments from '$comments_file' (a JSON array of comments with a \"body\") to find its review verdict." >&2; exit 1; }
  else
    verdicts=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" --jq "$REVIEW_JQ") ||
      { echo "merge-pr: could not read the comments of PR $pr to find its review verdict; not merging." >&2; exit 1; }
  fi
  last=$(printf '%s\n' "$verdicts" | awk 'NF == 2 { l = $0 } END { print l }')
  word=${last%% *}; sha=${last#* }
  if [ -z "$last" ]; then
    echo "merge-pr: PR $pr has no \"Fresh-context review: MERGE @ <sha>\" comment; get a fresh-context review and post its verdict on the PR first." >&2
    exit 1
  fi
  if [ "$word" != "MERGE" ]; then
    echo "merge-pr: PR $pr's latest review verdict is ${word//_/ }, not MERGE; fix the findings and get a new review." >&2
    exit 1
  fi
  if [ "$sha" = "-" ]; then
    echo "merge-pr: PR $pr's MERGE verdict names no reviewed commit; post it as \"Fresh-context review: MERGE @ <head sha>\"." >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
    echo "merge-pr: PR $pr's MERGE verdict reviewed $sha, which is not in the head's history (unknown sha or rewritten history); get a review of $head." >&2
    exit 1
  fi
  revs=$(git rev-list --no-merges "$sha..$head" ^origin/develop) || { echo "merge-pr: git rev-list $sha..$head failed." >&2; exit 1; }
  for c in $revs; do
    files=$(git diff-tree --no-commit-id --name-only -r "$c") || { echo "merge-pr: git diff-tree $c failed; not merging." >&2; exit 1; }
    if printf '%s\n' "$files" |
      awk '$0 != "" && $0 != ".claude-plugin/plugin.json" && $0 != ".claude-plugin/marketplace.json" { f = 1 } END { exit !f }'; then
      echo "merge-pr: PR $pr changed after its MERGE review of $sha: commit $c touches more than the manifests; get a review of $head." >&2
      exit 1
    fi
  done
}

wait_for_load() {
  local load_max="${MERGE_PR_LOAD_MAX:-4}" wait_secs="${MERGE_PR_LOAD_WAIT_SECS:-900}" waited=0 load
  while :; do
    load=$(uptime | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{print $1}')
    if awk -v l="$load" -v m="$load_max" 'BEGIN { exit !(l + 0 < m + 0) }'; then
      return 0
    fi
    if [ "$waited" -ge "$wait_secs" ]; then
      die "load $load is still >= $load_max after ${waited}s; not merging."
    fi
    sleep 30
    waited=$((waited + 30))
  done
}

remote_head() {
  local line
  line=$(git ls-remote origin "refs/heads/$branch") || die "git ls-remote origin failed; not merging."
  printf '%s\n' "${line%%[[:space:]]*}"
}

require_unchanged_after_gauntlet() {
  local dirty
  dirty=$(git status --porcelain) || die "git status failed."
  if [ -n "$dirty" ]; then
    die "the checkout changed while the pre-push gauntlet ran, so its result does not cover $head. Clean the checkout and run merge-pr.sh again; it runs the gauntlet again first."
  fi
}

# run_gauntlet_here: origin already has $head, pushed by an earlier run or by the PR's author (who may
# have edited the tree during that gauntlet, or pushed with hooks off), so run the pre-push hook on this
# clean tree before merging it.
run_gauntlet_here() {
  local hook
  hook=$(git rev-parse --git-path hooks/pre-push) || die "cannot find the pre-push hook path."
  if [ ! -x "$hook" ]; then
    die "no executable pre-push hook at $hook, so nothing would run the gauntlet on $head; set core.hooksPath (git config core.hooksPath git-hooks)."
  fi
  echo "merge-pr: origin already has $head; running the pre-push gauntlet on it before merging." >&2
  env -u MH_GAUNTLET_LOCK_OWNER "$hook" origin origin </dev/null || die "the pre-push gauntlet failed on $head; fix it, commit, and run merge-pr.sh again (a fix commit needs a new review verdict)."
  require_unchanged_after_gauntlet
}

# push_head: push HEAD to the PR branch (the pre-push gauntlet runs on this tree) and wait until GitHub
# shows it as the PR head. A push that exits non-zero after the hook passed (exit 141, an idle SSH
# drop) still counts when origin has the commit.
push_head() {
  local rc=0 remote n=0 ssh_cmd
  # git opens the SSH connection before the pre-push hook runs, so it idles through the whole gauntlet
  # and GitHub drops it (exit 141 on #634's first merge run, 2026-10-26): keep it alive, with the
  # 10 s x 30 setting that held on 2026-09-30.
  ssh_cmd="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand || echo "${GIT_SSH:-ssh}")} -o ServerAliveInterval=10 -o ServerAliveCountMax=30"
  # MH_GAUNTLET_LOCK_OWNER is this script's merge-lock pid; the hook must queue on the gauntlet lock.
  env -u MH_GAUNTLET_LOCK_OWNER GIT_SSH_COMMAND="$ssh_cmd" git push origin "HEAD:refs/heads/$branch" || rc=$?
  remote=$(remote_head) || exit 1
  if [ "$remote" != "$head" ]; then
    die "the push of $head to $branch did not land (origin has ${remote:-nothing}, push rc=$rc). If the pre-push gauntlet failed, fix it, commit, and run merge-pr.sh again: the sync and version commits stay on the local branch, and a fix commit needs a new review verdict."
  fi
  require_unchanged_after_gauntlet
  [ "$rc" -eq 0 ] || echo "merge-pr: git push exited $rc but origin has $head; going on." >&2
  until [ "$(gh pr view "$pr" --json headRefOid -q .headRefOid)" = "$head" ]; do
    n=$((n + 1))
    [ "$n" -lt 20 ] || die "GitHub still shows another head for PR $pr a minute after the push of $head; run merge-pr.sh again."
    sleep 3
  done
}

# Refuse a PR whose review does not cover it before the script writes anything.
check_review

# --verify: the checks alone; a session without gh syncs with sync-pr-head.sh and merges through MCP.
if [ "$verify" = 1 ]; then
  rc=0
  git merge-base --is-ancestor origin/develop "$head" || rc=$?
  [ "$rc" -le 1 ] || die "ancestry check against origin/develop failed (rc=$rc); is $head fetched?"
  if [ "$rc" -eq 1 ]; then
    die "PR $pr head $head does not contain origin/develop; $(resync_hint)."
  fi
  check_version
  echo "merge-pr: PR $pr passes at $head (base develop, contains origin/develop, version above it, review MERGE); merge it pinned to that sha now, and verify again if develop moves first." >&2
  echo "$head"
  exit 0
fi

merge_lock_take
if [ "$GAUNTLET_LOCK_HELD" != 1 ]; then
  die "could not take the merge lock at $merge_lock_dir within ${MERGE_PR_LOCK_WAIT_SECS:-3600}s (another merge-pr.sh is running, or the dir cannot be made); not merging."
fi
# develop may have moved while this run waited for the lock.
git fetch origin || die "git fetch failed after taking the merge lock; not merging."

round=1
while :; do
  wait_for_load
  require_clean "after the lock and load waits"
  sync_and_bump
  head=$(git rev-parse HEAD)
  check_version
  check_review
  remote=$(remote_head) || exit 1
  require_clean "before the gauntlet"
  if [ "$remote" != "$head" ]; then
    push_head
  else
    run_gauntlet_here
  fi
  # A merge made outside this script lands no matter the lock: fetch, and sync again if it did.
  git fetch origin || die "git fetch failed after the push; not merging."
  rc=0
  git merge-base --is-ancestor origin/develop "$head" || rc=$?
  [ "$rc" -eq 0 ] && break
  [ "$rc" -eq 1 ] || die "ancestry check against origin/develop failed (rc=$rc)."
  [ "$round" -lt 3 ] || die "origin/develop moved during each of 3 rounds (merges made outside merge-pr.sh?); not merging."
  round=$((round + 1))
  echo "merge-pr: origin/develop moved while $head was pushed; syncing again (round $round of 3)." >&2
done
check_version
check_review

now=$(gh pr view "$pr" --json baseRefName -q .baseRefName)
if [ "$now" != "develop" ]; then
  die "PR $pr base changed to '$now' while waiting; not merging."
fi

gh pr merge "$pr" --merge --match-head-commit "$head"
gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid
