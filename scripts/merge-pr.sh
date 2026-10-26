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
set -euo pipefail

pr="${1:-}"
if [ -z "$pr" ]; then
  echo "usage: merge-pr.sh <PR number>" >&2
  exit 2
fi

git fetch origin

info=$(gh pr view "$pr" --json headRefOid,baseRefName -q '.headRefOid + " " + .baseRefName')
head=${info% *}
base=${info#* }
if [ -z "$head" ] || [ "$head" = "$info" ]; then
  echo "merge-pr: could not read the head sha and base branch of PR $pr" >&2
  exit 1
fi
if [ "$base" != "develop" ]; then
  echo "merge-pr: PR $pr targets '$base', not develop; the origin/develop check would prove nothing." >&2
  echo "Retarget it (gh pr edit $pr --base develop) or ask the operator; do not fall back to a bare gh pr merge." >&2
  exit 1
fi

sync_script="${MERGE_PR_SYNC:-$(cd -P "$(dirname "$0")" && pwd)/sync-pr-head.sh}"
tries="${MERGE_PR_SYNC_TRIES:-3}"
# A non-number would make the round cap's `[ -ge ]` fail as false, so the cap would never stop the loop.
case "$tries" in
  '' | *[!0-9]*)
    echo "merge-pr: MERGE_PR_SYNC_TRIES must be a whole number of sync rounds, not '$tries'." >&2
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
  verdicts=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" --jq "$REVIEW_JQ") ||
    { echo "merge-pr: could not read the comments of PR $pr to find its review verdict; not merging." >&2; exit 1; }
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
# The review is checked first: an unreviewed PR is refused before the load wait and before any push.
check_review

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
