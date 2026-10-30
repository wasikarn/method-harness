#!/usr/bin/env bash
# sync-pr-head.sh <branch> <head sha> — bring a PR head up to origin/develop and give it the next
# version, so a feature branch never bumps the manifests itself. This is the sync for a session without
# gh (a cloud session): run it, then `merge-pr.sh --verify` on the sha it prints, then the MCP merge.
# merge-pr.sh's gh path syncs in the caller's checkout instead. While every branch bumped its own,
# develop's version moved 48 times in six hours and each open PR had to re-merge and re-bump after
# every one (#618 took five rounds).
#
# When the head already contains origin/develop and ships a version above it, it runs the gauntlet on it
# (step 3) and prints the head, pushing nothing. Otherwise, in a temporary worktree at the head:
#   1. merge origin/develop (if the head lacks it). A manifest conflict takes develop's side only when
#      the branch changed nothing in that manifest but its version line (the conflict is the version
#      bump next to another line); a manifest the branch edited otherwise, or any other conflict,
#      aborts: the branch's own change needs a person, so merge develop yourself. Taking develop's
#      whole file would silently drop the branch's edit (PR #644 review).
#   2. set both manifests to the head's own version when it is above develop's (a deliberate bump,
#      say a minor one), else develop's + 1, in one manifest-only commit.
#   3. run the full gauntlet on that exact tree, under the gauntlet lock, unless a pass is cached for it
#      (scripts/_lib/gauntlet-pass.sh; GAUNTLET_PASS_CACHE=0 forces the run). Since GH #735 a push runs
#      only a fast lint, so this is the gate on the tree that merges; a red gauntlet pushes nothing.
#   4. push to origin/<branch>, leased on <head>, with merge-pr.sh's SSH keepalive; a branch that is no
#      longer exactly <head> (someone pushed or rewound it) is refused. A push that exits non-zero but
#      landed (ls-remote) still counts.
# Prints the new head sha on stdout; everything else goes to stderr. The caller fetches origin first.
# Both commits keep a PR's review verdict (merge-pr.sh check_review): the version commit changes only the
# manifests' version value, and since GH #629 a merge keeps it only as a plain two-parent merge whose
# conflicts were all in the manifests and differ from the merge with the version set aside only in that
# value, which is the one step 1 makes.
# Bash 3.2.
set -euo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/gauntlet-lock.sh
. "$HERE/_lib/gauntlet-lock.sh"
# shellcheck source=_lib/gauntlet-pass.sh
. "$HERE/_lib/gauntlet-pass.sh"

branch="${1:-}" head="${2:-}"
if [ -z "$branch" ] || [ -z "$head" ]; then
  echo "usage: sync-pr-head.sh <branch> <head sha>" >&2
  exit 2
fi
PJ=.claude-plugin/plugin.json
MJ=.claude-plugin/marketplace.json

# First "version" value in a manifest at a ref, or in a file with ref "-".
version_of() {
  local raw
  if [ "$1" = - ]; then raw=$(cat "$2"); else raw=$(git show "$1:$2") || return 1; fi
  printf '%s\n' "$raw" | awk -F'"' '/"version"/ && !seen { print $4; seen = 1 }'
}
# version_lt A B: exit 0 when dotted version A is lower than B.
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}
# Copy stdin with the first "version" value blanked (merge-pr.sh's with_version, with a placeholder).
without_version() {
  awk '!done && /"version"/ { done = sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"\"") } { print }'
}
is_xyz() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

dev_ver=$(version_of origin/develop "$PJ") || { echo "sync-pr-head: cannot read $PJ at origin/develop." >&2; exit 1; }
head_ver=$(version_of "$head" "$PJ") || { echo "sync-pr-head: cannot read $PJ at $head." >&2; exit 1; }
for v in "$dev_ver" "$head_ver"; do
  is_xyz "$v" || { echo "sync-pr-head: manifest version '$v' is not X.Y.Z; cannot order it." >&2; exit 1; }
done
if version_lt "$dev_ver" "$head_ver"; then
  target=$head_ver
else
  target=$(awk -v v="$dev_ver" 'BEGIN { split(v, x, "."); printf "%d.%d.%d\n", x[1], x[2], x[3] + 1 }')
fi

behind=0
git merge-base --is-ancestor origin/develop "$head" || behind=$?
if [ "$behind" -gt 1 ]; then
  echo "sync-pr-head: ancestry check failed (rc=$behind); is $head fetched?" >&2
  exit 1
fi
synced=0
if [ "$behind" -eq 0 ] && [ "$head_ver" = "$target" ] && [ "$(version_of "$head" "$MJ")" = "$target" ]; then
  synced=1
fi

wt=$(mktemp -d "${TMPDIR:-/tmp}/sync-pr-head.XXXXXX") || { echo "sync-pr-head: mktemp -d failed." >&2; exit 1; }
cleanup() {
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  rmdir "$wt" 2>/dev/null || true  # left empty when `git worktree add` failed
}
trap cleanup EXIT
git worktree add -q --detach "$wt" "$head" >&2

if [ "$synced" -eq 1 ]; then
  # Nothing to push, but the author's own push ran only a lint (GH #735): the merge still needs a gauntlet.
  (cd "$wt" && gauntlet_full sync-pr-head) || { echo "sync-pr-head: the gauntlet failed on $head; fix it, commit, push, and get a new review." >&2; exit 1; }
  echo "$head"
  exit 0
fi

if [ "$behind" -eq 1 ]; then
  if ! git -C "$wt" merge -q --no-edit -m "Merge origin/develop into $branch" origin/develop >&2; then
    conflicted=$(git -C "$wt" diff --name-only --diff-filter=U)
    others=$(printf '%s\n' "$conflicted" | awk -v p="$PJ" -v m="$MJ" '$0 != "" && $0 != p && $0 != m')
    # A conflicted manifest the branch changed beyond its version line: develop's side would drop that.
    base=$(git merge-base origin/develop "$head")
    for f in "$PJ" "$MJ"; do
      /usr/bin/grep -qxF "$f" <<<"$conflicted" || continue
      # Only the first "version" value is set aside, as merge-pr.sh check_review does: the rest of that
      # line (a "hooks" key after it, say) is an edit too.
      if ! { a=$(git show "$base:$f" | without_version) && b=$(git show "$head:$f" | without_version) && [ "$a" = "$b" ]; }; then
        others=$(printf '%s\n%s (the branch changed more than its version line)' "$others" "$f" | awk 'NF')
      fi
    done
    if [ -n "$others" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      echo "sync-pr-head: merging origin/develop into $branch conflicts in files it cannot resolve:" >&2
      printf '%s\n' "$others" | sed 's/^/  /' >&2
      echo "Merge origin/develop into the branch yourself, resolve, and push (a conflict resolved outside the manifests needs a new review); then fetch, run sync-pr-head.sh again on the new head, and merge-pr.sh --verify the sha it prints." >&2
      exit 1
    fi
    for f in "$PJ" "$MJ"; do
      /usr/bin/grep -qxF "$f" <<<"$conflicted" || continue
      git -C "$wt" checkout -q --theirs -- "$f"
      git -C "$wt" add -- "$f"
    done
    git -C "$wt" commit -q --no-edit >&2
  fi
fi

for f in "$PJ" "$MJ"; do
  awk -v v="$target" '!done && /"version"[[:space:]]*:/ {
      sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" v "\""); done = 1 }
    { print }' "$wt/$f" >"$wt/$f.sync-tmp"
  mv "$wt/$f.sync-tmp" "$wt/$f"
  [ "$(version_of - "$wt/$f")" = "$target" ] || { echo "sync-pr-head: could not set $f to $target." >&2; exit 1; }
done
if ! git -C "$wt" diff --quiet -- "$PJ" "$MJ"; then
  git -C "$wt" add -- "$PJ" "$MJ"
  git -C "$wt" commit -q -m "chore: bump mh to $target (merge-pr.sh; origin/develop at $dev_ver)" >&2
fi

new=$(git -C "$wt" rev-parse HEAD)
(cd "$wt" && gauntlet_full sync-pr-head) || { echo "sync-pr-head: the gauntlet failed on $new (the merge of origin/develop and the version bump), so nothing was pushed; fix it on the branch, push, and get a new review." >&2; exit 1; }
# The keepalive dates from the pre-push hook running the whole gauntlet while the SSH connection idled
# (exit 141); the same as merge-pr.sh's push_head, cheap, for a hook run with MH_PREPUSH_FULL=1.
ssh_cmd="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand || echo "${GIT_SSH:-ssh}")} -o ServerAliveInterval=10 -o ServerAliveCountMax=30"
rc=0
GIT_SSH_COMMAND="$ssh_cmd" git -C "$wt" push --force-with-lease="refs/heads/$branch:$head" origin "HEAD:refs/heads/$branch" >&2 || rc=$?
line=$(git ls-remote origin "refs/heads/$branch") || { echo "sync-pr-head: git ls-remote origin failed after the push (rc=$rc)." >&2; exit 1; }
if [ "${line%%[[:space:]]*}" != "$new" ]; then
  echo "sync-pr-head: push to origin/$branch failed (rc=$rc): either the branch is no longer at $head (fetch and run sync-pr-head.sh on the new head) or the pre-push lint failed (fix, commit, push, and get a new review)." >&2
  exit 1
fi
[ "$rc" -eq 0 ] || echo "sync-pr-head: git push exited $rc but origin has $new; going on." >&2
echo "$new"
