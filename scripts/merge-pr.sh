#!/usr/bin/env bash
# merge-pr.sh <PR> — merge a PR only if its head contains the origin/develop tip
# and whose base is develop (GH #450). The pre-push gauntlet then ran on the exact tree that merges, so two
# PRs green alone cannot land red together (#445 + #446). --match-head-commit
# pins the merge to the checked sha: a push after the check makes GitHub refuse.
# Checks are local-only; this narrows the race, it does not close it. It also refuses a PR with no
# fresh review verdict (see check_review).
# Branches do not bump the version: after the load wait, a head that lacks origin/develop or does not
# ship a version above it is synced by scripts/sync-pr-head.sh (merge develop, bump both manifests,
# push), up to MERGE_PR_SYNC_TRIES times while develop keeps moving, then checked and merged.
# Bash 3.2. Env: MERGE_PR_LOAD_MAX (default 4), MERGE_PR_LOAD_WAIT_SECS (900),
# MERGE_PR_ALLOW_SAME_VERSION (1: a version equal to develop's needs no bump), MERGE_PR_SYNC_TRIES (3),
# MERGE_PR_SYNC (the sync script; tests only).
#
# merge-pr.sh --verify <PR> <head sha> <base branch> <comments.json> — the same checks without gh, for a
# session that has no gh (a Claude Code cloud session) and merges through the GitHub MCP tools instead.
# The caller passes what those tools return: the PR's head sha and base branch, and its issue comments
# as a JSON array of objects with a "body" (read through the same verdict parser as the gh path). It
# runs the base, review, ancestry and version checks and never syncs, pushes or merges: a head that
# lacks origin/develop or a version above it is refused with the sync-pr-head.sh command to run first.
# On a pass it prints the head sha; merge it pinned to that sha (expectedHeadSha) right away. Before
# this mode, cloud sessions retyped these checks by hand for every merge (#633, #644, #648).
set -euo pipefail

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

git fetch origin

if [ "$verify" = 0 ]; then
  info=$(gh pr view "$pr" --json headRefOid,baseRefName -q '.headRefOid + " " + .baseRefName')
  head=${info% *}
  base=${info#* }
  if [ -z "$head" ] || [ "$head" = "$info" ]; then
    echo "merge-pr: could not read the head sha and base branch of PR $pr" >&2
    exit 1
  fi
fi
if [ "$base" != "develop" ]; then
  echo "merge-pr: PR $pr targets '$base', not develop; the origin/develop check would prove nothing." >&2
  echo "Retarget it (gh pr edit $pr --base develop) or ask the operator; do not fall back to a bare gh pr merge." >&2
  exit 1
fi

sync_script="${MERGE_PR_SYNC:-$(cd -P "$(dirname "$0")" && pwd)/sync-pr-head.sh}"
tries="${MERGE_PR_SYNC_TRIES:-3}"
# A non-number, or one too big for bash's integers, would make the round cap's `[ -ge ]` fail as false,
# so the cap would never stop the loop. Five digits or more is refused well below that.
case "$tries" in
  '' | *[!0-9]* | ?????*)
    echo "merge-pr: MERGE_PR_SYNC_TRIES must be a whole number of sync rounds below 10000, not '$tries'." >&2
    exit 2 ;;
esac

check_ancestry() {
  local rc=0
  git merge-base --is-ancestor origin/develop "$head" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "merge-pr: PR $pr head $head does not contain origin/develop." >&2
    echo "Merge origin/develop into the branch and push (a rebase loses the review); the pre-push gauntlet then runs on the exact tree that will merge." >&2
    exit 1
  elif [ "$rc" -ne 0 ]; then
    echo "merge-pr: ancestry check failed (rc=$rc); is $head fetched locally?" >&2
    exit 1
  fi
}

# Refuse a head whose version is not above origin/develop's: an identical bump rebases away
# with no conflict, so two PRs can cut one number (#492/#493, #496/#497), and a conflict
# resolved to the older number leaves the head below. Both manifests must agree at the head, and
# all versions must be plain X.Y.Z so they order safely. MERGE_PR_ALLOW_SAME_VERSION=1 skips
# only the equal-version refusal, for a PR that needs no bump.
manifest_version() {
  local raw
  raw=$(git show "$1:$2") || { echo "merge-pr: cannot read $2 at $1." >&2; exit 1; }
  # First "version" key; awk reads all of its input, so no SIGPIPE under pipefail.
  printf '%s\n' "$raw" | awk -F'"' '/"version"/ && !seen { print $4; seen = 1 }'
}
# version_lt A B: exit 0 when dotted version A is lower than B.
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}
# version_problem: why the head's version cannot merge over origin/develop's, or nothing when it can.
# Prints, never exits: the sync loop asks it whether to sync, check_version turns it into a refusal.
version_problem() {
  local head_ver mkt_ver dev_ver v
  head_ver=$(manifest_version "$head" .claude-plugin/plugin.json) || { echo "cannot read .claude-plugin/plugin.json at $head."; return; }
  mkt_ver=$(manifest_version "$head" .claude-plugin/marketplace.json) || { echo "cannot read .claude-plugin/marketplace.json at $head."; return; }
  dev_ver=$(manifest_version origin/develop .claude-plugin/plugin.json) || { echo "cannot read .claude-plugin/plugin.json at origin/develop."; return; }
  if [ -z "$head_ver" ] || [ -z "$mkt_ver" ] || [ -z "$dev_ver" ]; then
    echo "could not read the manifest version of the PR head or origin/develop."
    return
  fi
  for v in "$head_ver" "$mkt_ver" "$dev_ver"; do
    if ! [[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
      echo "manifest version '$v' is not X.Y.Z; cannot order it against origin/develop."
      return
    fi
  done
  if [ "$head_ver" != "$mkt_ver" ]; then
    echo "PR $pr head has plugin.json $head_ver but marketplace.json $mkt_ver."
  elif version_lt "$head_ver" "$dev_ver"; then
    echo "PR $pr head ships version $head_ver, below origin/develop's $dev_ver."
  elif [ "$head_ver" = "$dev_ver" ] && [ "${MERGE_PR_ALLOW_SAME_VERSION:-}" != "1" ]; then
    echo "PR $pr head ships version $head_ver, the same as origin/develop."
  fi
}
check_version() {
  local why
  why=$(version_problem)
  if [ -n "$why" ]; then
    echo "merge-pr: $why Not merging." >&2
    exit 1
  fi
}
# Refuse a PR with no current review verdict. On 2026-10-25 #569–#576 and #611 merged while their reviews
# still said FIX FIRST, and #570 opened a hole (`env -S -i rm -rf build` allowed) that took #602 to close.
# The verdict is a line "Fresh-context review: MERGE @ <sha>" (or FIX FIRST / CLOSE) in a PR comment,
# <sha> being the head the reviewer read. The last verdict on the PR must be MERGE, and every commit after
# <sha> must be a merge of develop or touch only the two manifests (a version bump): a sync before the merge
# keeps the review, any other change needs a new one. Binding to the sha, not to times, means a commit made
# before the review but pushed after it, or a backdated one, is still caught. A merge commit counts only
# when its tree is what `git merge-tree` makes of its two parents, the manifests aside (GH #629: an edit
# made inside a merge, or a conflict resolved in code, needs a new review). A line inside a ``` or ~~~
# fence does not count (a fence closes only on the same character, at least as long, as CommonMark has
# it), and the last verdict line in a comment wins. Only issue comments are read (not PR reviews or the
# body). This proves a verdict was posted, not who wrote it or that the reviewer had fresh context
# (CLAUDE.md asks for that). There is no opt-out: an operator who must merge without a verdict does it on
# GitHub.
REVIEW_JQ='.[] | (.body | split("\n") | reduce .[] as $l ({f: null, m: null};
    (($l | capture("^ {0,3}(?<c>`{3,}|~{3,})") | .c) // null) as $fc
    | if .f == null and $fc != null then .f = $fc
    elif .f != null then (if $fc != null and ($fc[0:1] == .f[0:1]) and ($fc | length) >= (.f | length) then .f = null else . end)
    else ((($l | capture("^[#*\\s]*fresh-context review\\s*:\\s*\\**\\s*(?<v>MERGE|FIX FIRST|CLOSE)\\b(?<r>.*)$"; "i")) as $c | .m = $c) // .)
    end) | .m) as $m
  | select($m != null)
  | "\($m.v | ascii_upcase | gsub(" "; "_")) \(($m.r | capture("^[*\\s]*@\\s*`?(?<s>[0-9a-fA-F]{7,40})\\b") | .s) // "-")"'
check_review() {
  local verdicts last word sha revs c files merges parents p1 p2 tree rc
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
  # A merge after the review must be the plain merge of its two parents (GH #629); git merge-tree --write-tree
  # (git >= 2.38) prints that tree first, exiting 1 when it holds conflicts (a conflicted manifest is fine).
  merges=$(git rev-list --merges "$sha..$head" ^origin/develop) || { echo "merge-pr: git rev-list --merges $sha..$head failed." >&2; exit 1; }
  for c in $merges; do
    parents=$(git rev-list --parents -n 1 "$c") || { echo "merge-pr: cannot read the parents of $c." >&2; exit 1; }
    parents=${parents#* }; p1=${parents%% *}; p2=${parents#* }
    if [ "$p2" = "$parents" ] || [ "${p2#* }" != "$p2" ]; then
      echo "merge-pr: PR $pr's merge commit $c after its MERGE review of $sha does not have exactly two parents; get a review of $head." >&2
      exit 1
    fi
    rc=0; tree=$(git merge-tree --write-tree --no-messages "$p1" "$p2") || rc=$?
    if [ "$rc" -gt 1 ]; then echo "merge-pr: git merge-tree of $c's parents failed (rc=$rc; needs git >= 2.38); not merging." >&2; exit 1; fi
    tree=${tree%%$'\n'*}
    files=$(git diff --name-only "$tree" "$c^{tree}") || { echo "merge-pr: git diff of merge commit $c failed; not merging." >&2; exit 1; }
    if printf '%s\n' "$files" |
      awk '$0 != "" && $0 != ".claude-plugin/plugin.json" && $0 != ".claude-plugin/marketplace.json" { f = 1 } END { exit !f }'; then
      echo "merge-pr: PR $pr's merge commit $c after its MERGE review of $sha changes more than merging its parents does (beyond the manifests); get a review of $head." >&2
      exit 1
    fi
  done
}
# The review is checked first: an unreviewed PR is refused before the load wait and before any push.
check_review

if [ "$verify" = 1 ]; then
  if ! git merge-base --is-ancestor origin/develop "$head" 2>/dev/null || [ -n "$(version_problem)" ]; then
    why=$(version_problem)
    echo "merge-pr: PR $pr head $head is not synced with origin/develop (${why:-it lacks the origin/develop tip})." >&2
    echo "Run scripts/sync-pr-head.sh <head branch> $head, then --verify the sha it prints." >&2
    exit 1
  fi
  check_ancestry
  check_version
  echo "merge-pr: PR $pr passes at $head (base develop, contains origin/develop, version above it, review MERGE); merge it pinned to that sha now, and verify again if develop moves first." >&2
  echo "$head"
  exit 0
fi

load_max="${MERGE_PR_LOAD_MAX:-4}"
wait_secs="${MERGE_PR_LOAD_WAIT_SECS:-900}"
waited=0
while :; do
  load=$(uptime | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{print $1}')
  if awk -v l="$load" -v m="$load_max" 'BEGIN { exit !(l + 0 < m + 0) }'; then
    break
  fi
  if [ "$waited" -ge "$wait_secs" ]; then
    echo "merge-pr: load $load is still >= $load_max after ${waited}s; not merging." >&2
    exit 1
  fi
  sleep 30
  waited=$((waited + 30))
done

# Sync: develop can move during the load wait and during each sync's push (the pre-push gauntlet takes
# minutes), so fetch and re-check after every round. Branches do not bump; this does.
branch_info=$(gh pr view "$pr" --json headRefName,isCrossRepository -q '.headRefName + " " + (.isCrossRepository | tostring)')
branch=${branch_info% *}
cross=${branch_info#* }
round=0
while :; do
  git fetch origin || { echo "merge-pr: git fetch failed after the load wait; not merging." >&2; exit 1; }
  if git merge-base --is-ancestor origin/develop "$head" 2>/dev/null && [ -z "$(version_problem)" ]; then
    break
  fi
  if [ "$round" -ge "$tries" ]; then
    echo "merge-pr: PR $pr is still not synced with origin/develop after $tries sync rounds (develop keeps moving); run merge-pr.sh again." >&2
    exit 1
  fi
  if [ -z "$branch" ] || [ "$branch" = "$branch_info" ] || [ "$cross" != "false" ]; then
    echo "merge-pr: PR $pr needs a sync with origin/develop, but its head branch is not a branch of this repo ('$branch_info'); merge develop and bump the manifests on it yourself." >&2
    exit 1
  fi
  round=$((round + 1))
  echo "merge-pr: syncing PR $pr ($branch) with origin/develop, round $round of $tries" >&2
  head=$(bash "$sync_script" "$branch" "$head") || { echo "merge-pr: syncing PR $pr failed (see above); not merging." >&2; exit 1; }
done
check_ancestry
check_version
check_review

now=$(gh pr view "$pr" --json baseRefName -q .baseRefName)
if [ "$now" != "develop" ]; then
  echo "merge-pr: PR $pr base changed to '$now' while waiting; not merging." >&2
  exit 1
fi

gh pr merge "$pr" --merge --match-head-commit "$head"
gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid
