#!/usr/bin/env bash
# merge-pr.sh <PR> — merge a PR only if its head contains the origin/develop tip
# and whose base is develop (GH #450). The pre-push gauntlet then ran on the exact tree that merges, so two
# PRs green alone cannot land red together (#445 + #446). --match-head-commit
# pins the merge to the checked sha: a push after the check makes GitHub refuse.
# Checks are local-only; this narrows the race, it does not close it. It also refuses a PR with no
# fresh review verdict (see check_review).
# Bash 3.2. Env: MERGE_PR_LOAD_MAX (default 4), MERGE_PR_LOAD_WAIT_SECS (900),
# MERGE_PR_ALLOW_SAME_VERSION (1 skips the same-manifest-version refusal).
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

check_ancestry() {
  local rc=0
  git merge-base --is-ancestor origin/develop "$head" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "merge-pr: PR $pr head $head does not contain origin/develop." >&2
    echo "Rebase on origin/develop and push; the pre-push gauntlet then runs on the exact tree that will merge." >&2
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
check_version() {
  local head_ver mkt_ver dev_ver v
  head_ver=$(manifest_version "$head" .claude-plugin/plugin.json)
  mkt_ver=$(manifest_version "$head" .claude-plugin/marketplace.json)
  dev_ver=$(manifest_version origin/develop .claude-plugin/plugin.json)
  if [ -z "$head_ver" ] || [ -z "$mkt_ver" ] || [ -z "$dev_ver" ]; then
    echo "merge-pr: could not read the manifest version of the PR head or origin/develop." >&2
    exit 1
  fi
  for v in "$head_ver" "$mkt_ver" "$dev_ver"; do
    if ! [[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
      echo "merge-pr: manifest version '$v' is not X.Y.Z; cannot order it against origin/develop." >&2
      exit 1
    fi
  done
  if [ "$head_ver" != "$mkt_ver" ]; then
    echo "merge-pr: PR $pr head has plugin.json $head_ver but marketplace.json $mkt_ver; bump both manifests to the same number." >&2
    exit 1
  fi
  if version_lt "$head_ver" "$dev_ver"; then
    echo "merge-pr: PR $pr head ships version $head_ver, below origin/develop's $dev_ver; the branch is stale or a conflict was resolved to the older number. Bump both manifests above $dev_ver." >&2
    exit 1
  fi
  if [ "$head_ver" = "$dev_ver" ] && [ "${MERGE_PR_ALLOW_SAME_VERSION:-}" != "1" ]; then
    echo "merge-pr: PR $pr head ships version $head_ver, the same as origin/develop; bump both manifests to the next number first (or MERGE_PR_ALLOW_SAME_VERSION=1)." >&2
    exit 1
  fi
}
# Refuse a PR with no fresh review verdict. On 2026-10-25 #569–#576 and #611 merged while their reviews
# still said FIX FIRST, and #570 opened a hole (`env -S -i rm -rf build` allowed) that took #602 to close.
# The verdict is a line "Fresh-context review: MERGE" (or FIX FIRST / CLOSE) in a PR comment; the latest
# verdict posted after the PR's last substantive commit must be MERGE. A merge of develop and a commit
# touching only the two manifests (a version bump) are not substantive, so syncing before the merge keeps
# the review; any other commit needs a new one. This proves a verdict was posted, not who wrote it or that
# the reviewer had fresh context (CLAUDE.md asks for that), and a conflict resolved inside a merge commit
# is not counted. There is no opt-out: an operator who must merge without a verdict does it on GitHub.
REVIEW_JQ='.[] | (.created_at | fromdateiso8601) as $t
  | [.body | split("\n")[] | capture("^[#*\\s]*fresh-context review\\s*:\\s*\\**\\s*(?<v>MERGE|FIX FIRST|CLOSE)\\b"; "i") | .v] as $v
  | select($v | length > 0) | "\($t) \($v[0] | ascii_upcase | gsub(" "; "_"))"'
# Committer time (epoch) of the newest substantive commit between origin/develop and the head, 0 for none.
last_substantive_time() {
  local revs c t newest=0
  revs=$(git rev-list --no-merges "origin/develop..$head") || { echo "merge-pr: git rev-list failed for $head." >&2; exit 1; }
  for c in $revs; do
    if git diff-tree --no-commit-id --name-only -r "$c" |
      awk '$0 != "" && $0 != ".claude-plugin/plugin.json" && $0 != ".claude-plugin/marketplace.json" { f = 1 } END { exit !f }'; then
      t=$(git log -1 --format=%ct "$c")
      if [ "$t" -gt "$newest" ]; then newest=$t; fi
    fi
  done
  echo "$newest"
}
check_review() {
  local since verdicts last
  since=$(last_substantive_time)
  verdicts=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" --jq "$REVIEW_JQ") ||
    { echo "merge-pr: could not read the comments of PR $pr to find its review verdict; not merging." >&2; exit 1; }
  last=$(printf '%s\n' "$verdicts" | awk -v s="$since" 'NF == 2 && $1 > s { v = $2 } END { print v }')
  if [ "$last" = "MERGE" ]; then return 0; fi
  if [ -z "$last" ]; then
    echo "merge-pr: PR $pr has no \"Fresh-context review: MERGE\" comment posted after its last substantive commit; get a fresh-context review and post its verdict on the PR first." >&2
  else
    echo "merge-pr: PR $pr's latest review verdict after its last substantive commit is ${last//_/ }, not MERGE; fix the findings and get a new review." >&2
  fi
  exit 1
}
check_ancestry
check_version
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

# develop can move during the load wait: fetch and check both again.
git fetch origin || { echo "merge-pr: git fetch failed after the load wait; not merging." >&2; exit 1; }
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
