#!/usr/bin/env bash
# test-sync-pr-head.sh — scripts/sync-pr-head.sh, the no-gh sync a cloud session runs before
# `merge-pr.sh --verify`, so branches never bump the version: it merges origin/develop into a PR head (manifest conflicts take develop's side,
# any other conflict refuses), sets both manifests to develop's version + 1 (or the head's own when it
# is higher), runs the full gauntlet on that tree (GH #735: the push only lints), pushes to the PR branch
# and prints the new head. Real git: a bare origin, a develop that moved on, and a feature branch per
# case; the committed scripts/run-gauntlet.sh is a recorder that prints to stdout. Case 1 wires hooks
# that print to stdout (the real pre-push does), which must not reach the sha the script prints either.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_SSH_COMMAND GIT_SSH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
HERE="$(cd -P "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../scripts/sync-pr-head.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_tmp_delete() { [ -n "${1:-}" ] && python3 "$HERE/../_lib/tmp_delete.py" "$1"; return 0; }

ROOT_DIR="$(mktemp -d)"
[ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ] || { echo "mktemp -d failed" >&2; exit 1; }
export TMPDIR="$ROOT_DIR"
# The gauntlet lock and pass cache stay in the sandbox (the gauntlet's own test layer exports
# GAUNTLET_PASS_CACHE=0; these cases want the cache on).
export GAUNTLET_LOCK_DIR="$ROOT_DIR/gauntlet.lock" GAUNTLET_PASS_DIR="$ROOT_DIR/pass" GAUNTLET_PASS_CACHE=1
unset MH_GAUNTLET_LOCK_OWNER STUB_GAUNTLET_FAIL STUB_STATUS_FAIL
# gh: only the mh/gauntlet status post (GH #742) reaches it; it logs each call to $STUB_DIR/gh.log and
# fails when STUB_STATUS_FAIL is set, or with a 422 when the case's origin ($STUB_ORIGIN) lacks the sha
# (a status posted before the push). Never touches GitHub.
mkdir -p "$ROOT_DIR/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh $*" >>"$STUB_DIR/gh.log"' \
  '[ -z "${STUB_STATUS_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; }' \
  'for a in "$@"; do case "$a" in */statuses/*) sha=${a##*/} ;; esac; done' \
  'git --git-dir="$STUB_ORIGIN" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "HTTP 422: No commit found for SHA: $sha" >&2; exit 1; }' \
  >"$ROOT_DIR/bin/gh"
chmod +x "$ROOT_DIR/bin/gh"; export PATH="$ROOT_DIR/bin:$PATH"
# statuses <sha>: the status posts logged for <sha> (success, mh/gauntlet, naming its tree).
statuses() {
  [ -f "$STUB_DIR/gh.log" ] || { echo 0; return; }
  /usr/bin/grep -cxF "gh api --method POST repos/{owner}/{repo}/statuses/$1 -f state=success -f context=mh/gauntlet -f description=full gauntlet passed on tree $(git -C "$L" rev-parse "$1^{tree}")" "$STUB_DIR/gh.log"
}
# The fixture's full gauntlet: prints to stdout, counts its runs in $STUB_DIR/gauntlet.n, records the tree
# it ran on and what origin's feat/x held then, and fails when STUB_GAUNTLET_FAIL is set.
GAUNTLET_STUB='#!/usr/bin/env bash
echo "stub gauntlet ran"
n=0; [ ! -f "$STUB_DIR/gauntlet.n" ] || n=$(cat "$STUB_DIR/gauntlet.n"); echo $((n + 1)) >"$STUB_DIR/gauntlet.n"
echo "head=$(git rev-parse HEAD) dirty=$(git status --porcelain | tr "\n" " ")origin=$(git ls-remote origin refs/heads/feat/x | cut -f1) lock=$(cat "$GAUNTLET_LOCK_DIR/pid")" >>"$STUB_DIR/gauntlet.log"
[ -z "${STUB_GAUNTLET_FAIL:-}" ] || exit 1'
gauntlets() { if [ -f "$STUB_DIR/gauntlet.n" ]; then cat "$STUB_DIR/gauntlet.n"; else echo 0; fi; }

# manifests <dir> <version>: write both manifests the way the real ones are laid out (the version is
# not the only key, and marketplace.json nests it in the plugin entry).
manifests() {
  mkdir -p "$1/.claude-plugin"
  printf '{\n  "name": "mh",\n  "version": "%s",\n  "description": "d"\n}\n' "$2" >"$1/.claude-plugin/plugin.json"
  printf '{\n  "name": "m",\n  "plugins": [\n    {\n      "name": "mh",\n      "version": "%s",\n      "source": "."\n    }\n  ]\n}\n' "$2" >"$1/.claude-plugin/marketplace.json"
}
commit() { git -C "$1" ls-files -z -mo --exclude-standard | git -C "$1" add --pathspec-from-file=- --pathspec-file-nul && git -C "$1" commit -q -m "$2"; }
ver() { awk -F'"' '/"version"/ && !s { print $4; s = 1 }' "$1"; }

# setup [feature edit: none|bump:<v>|conflict|desc] [develop's new version, default 1.0.6] [develop's
# new description, default d]: origin with develop at 1.0.5, feat/x branched from it (b.txt, plus the
# edit), then develop moves on (c.txt, the new version and description). Sets O (bare origin), L (the
# clone the script runs in, fetched), HEAD_SHA (feat/x).
setup() {
  local d w
  d=$(mktemp -d "$ROOT_DIR/case.XXXXXX") || exit 1
  O="$d/origin.git"; w="$d/seed"; L="$d/local"; export STUB_DIR="$d" STUB_ORIGIN="$d/origin.git"
  git init -q --bare -b develop "$O"
  git init -q -b develop "$w"
  manifests "$w" 1.0.5; echo a >"$w/a.txt"
  mkdir -p "$w/scripts"; printf '%s\n' "$GAUNTLET_STUB" >"$w/scripts/run-gauntlet.sh"
  commit "$w" base
  git -C "$w" remote add origin "$O"; git -C "$w" push -q origin develop
  git -C "$w" checkout -q -b feat/x
  echo b >"$w/b.txt"
  case "${1:-none}" in
    bump:*) manifests "$w" "${1#bump:}" ;;
    conflict) echo a-feature >"$w/a.txt" ;;
    desc) sed 's/"description": "d"/"description": "d2"/' "$w/.claude-plugin/plugin.json" >"$w/p.tmp" && mv "$w/p.tmp" "$w/.claude-plugin/plugin.json" ;;
    hooks) sed 's|"version": "1.0.5",|"version": "1.0.5", "hooks": "./evil.json",|' "$w/.claude-plugin/plugin.json" >"$w/p.tmp" && mv "$w/p.tmp" "$w/.claude-plugin/plugin.json" ;;
  esac
  commit "$w" feature; git -C "$w" push -q origin feat/x
  git -C "$w" checkout -q develop
  echo c >"$w/c.txt"; manifests "$w" "${2:-1.0.6}"
  if [ -n "${3:-}" ]; then
    sed "s/\"description\": \"d\"/\"description\": \"$3\"/" "$w/.claude-plugin/plugin.json" >"$w/p.tmp" && mv "$w/p.tmp" "$w/.claude-plugin/plugin.json"
  fi
  [ "${1:-none}" = conflict ] && echo a-develop >"$w/a.txt"
  commit "$w" "develop moves"; git -C "$w" push -q origin develop
  git clone -q "$O" "$L"
  HEAD_SHA=$(git -C "$L" rev-parse origin/feat/x)
}
# run_sync <branch> <head>: run the script in L; sets rc, out (stdout), err.
run_sync() {
  out=$(cd "$L" && bash "$SCRIPT" "$1" "$2" 2>"$ROOT_DIR/err"); rc=$?
  err=$(cat "$ROOT_DIR/err")
}
remote_head() { git -C "$L" ls-remote origin refs/heads/feat/x | awk '{ print $1 }'; }
# worktrees_clean: the script left no worktree behind.
worktrees_clean() { [ "$(git -C "$L" worktree list | wc -l)" -eq 1 ]; }
# non-merge commits on the new head that are not on develop and not on the old head.
added() { git -C "$L" fetch -q origin && git -C "$L" rev-list --no-merges "$1" "^$HEAD_SHA" ^origin/develop; }

echo "=== sync-pr-head: merge develop, bump both manifests, push ==="

# 1. behind develop, the branch never bumped: merge, bump to develop + 1, push, print the new head. Every
# hook the sync can trigger (worktree checkout, merge, commit, push) prints to stdout here.
setup none
hk=$(mktemp -d "$ROOT_DIR/hooks.XXXXXX")
for h in post-checkout pre-merge-commit post-merge pre-commit commit-msg post-commit pre-push; do
  printf '#!/bin/sh\necho "%s hook says hi"\n' "$h" >"$hk/$h"; chmod +x "$hk/$h"
done
printf '#!/bin/sh\necho "pre-push hook says hi"\necho "ssh=$GIT_SSH_COMMAND"\n' >"$hk/pre-push"
git -C "$L" config core.hooksPath "$hk"
run_sync feat/x "$HEAD_SHA"
if /usr/bin/grep -qx 'ssh=ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=30' <<<"$err"; then
  ok "behind: the push keeps its SSH connection alive through the gauntlet"
else bad "behind: push ssh command: $err"; fi
if /usr/bin/grep -q 'pre-push hook says hi' <<<"$err" && ! /usr/bin/grep -q 'hook says hi' <<<"$out"; then
  ok "behind: the hooks ran, and their output went to stderr, not stdout"
else bad "behind: hook output: out='$out' err='$err'"; fi
new=$out
if [ "$(gauntlets)" = 1 ] && /usr/bin/grep -qE "^head=$new dirty=origin=$HEAD_SHA lock=[0-9]+\$" "$STUB_DIR/gauntlet.log" \
  && /usr/bin/grep -q 'stub gauntlet ran' <<<"$err" && ! /usr/bin/grep -q 'stub gauntlet ran' <<<"$out"; then
  ok "behind: the full gauntlet ran once, under the lock, on the clean pushed tree, before the push, output on stderr"
else bad "behind: gauntlet: $(cat "$STUB_DIR/gauntlet.log" 2>&1) out='$out'"; fi
if [ ! -e "$GAUNTLET_LOCK_DIR" ] && [ ! -d "$GAUNTLET_PASS_DIR" ]; then ok "behind: the gauntlet lock is released; no cache entry from the script itself"; else bad "behind: lock or pass dir left"; fi
if [ "$rc" -eq 0 ] && [ -n "$new" ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && [ "$(remote_head)" = "$new" ]; then
  ok "behind: exit 0, one line on stdout, and it is the pushed head"
else bad "behind: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi
git -C "$L" fetch -q origin
if git -C "$L" merge-base --is-ancestor origin/develop "$new" && git -C "$L" merge-base --is-ancestor "$HEAD_SHA" "$new"; then
  ok "behind: the new head contains origin/develop and the old head"
else bad "behind: ancestry wrong for $new"; fi
pj=$(git -C "$L" show "$new:.claude-plugin/plugin.json"); mj=$(git -C "$L" show "$new:.claude-plugin/marketplace.json")
if [ "$(ver <(printf '%s\n' "$pj"))" = 1.0.7 ] && [ "$(ver <(printf '%s\n' "$mj"))" = 1.0.7 ]; then
  ok "behind: both manifests at develop's 1.0.6 + 1"
else bad "behind: versions plugin=$(ver <(printf '%s\n' "$pj")) marketplace=$(ver <(printf '%s\n' "$mj"))"; fi
if /usr/bin/grep -q '"source": "."' <<<"$mj" && /usr/bin/grep -q '"description": "d"' <<<"$pj" \
  && [ "$(git -C "$L" diff origin/develop "$new" -- .claude-plugin | /usr/bin/grep -c '^[-+] ')" -eq 4 ]; then
  ok "behind: only the two version lines differ from develop's manifests"
else bad "behind: manifests rewritten beyond the version: $(git -C "$L" diff origin/develop "$new" -- .claude-plugin)"; fi
a=$(added "$new")
if [ "$(printf '%s\n' "$a" | /usr/bin/grep -c .)" -eq 1 ] \
  && [ "$(git -C "$L" diff-tree --no-commit-id --name-only -r "$a" | sort | tr '\n' ' ')" = ".claude-plugin/marketplace.json .claude-plugin/plugin.json " ]; then
  ok "behind: one non-merge commit added, touching only the manifests (keeps a review verdict)"
else bad "behind: added commits: $a"; fi
if worktrees_clean && [ "$(git -C "$L" status --porcelain | wc -l)" -eq 0 ]; then ok "behind: no worktree left, caller's tree untouched"; else bad "behind: worktrees: $(git -C "$L" worktree list)"; fi

# 2. the branch bumped too (the old convention) and develop moved past it: the manifest conflict (1.0.6
# against 1.0.8) takes develop's side, then bumps. develop also edited the line next to "version" (the
# description), so taking the branch's side instead would undo develop's edit on the merged tree.
setup bump:1.0.6 1.0.8 d-develop
if git -C "$L" merge-tree --write-tree origin/develop "$HEAD_SHA" >/dev/null 2>&1; then bad "case 2 setup does not conflict"; fi
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$(remote_head)" = "$out" ] && [ "$(git -C "$L" show "$out:.claude-plugin/plugin.json" | ver /dev/stdin)" = 1.0.9 ] \
  && [ "$(git -C "$L" show "$out:.claude-plugin/marketplace.json" | ver /dev/stdin)" = 1.0.9 ]; then
  ok "manifest-only conflict: resolved and bumped to 1.0.9"
else bad "manifest conflict: rc=$rc out='$out' err=$err"; fi
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '"description": "d-develop"' <<<"$(git -C "$L" show "$out:.claude-plugin/plugin.json")"; then
  ok "manifest-only conflict: develop's own edit next to the version survives (develop's side was taken)"
else bad "manifest conflict lost develop's description: $(git -C "$L" show "$out:.claude-plugin/plugin.json" 2>&1)"; fi

# 2b. the branch edited the line next to "version" (the description): develop's bump conflicts with it,
# and taking develop's side would drop the edit. Refuse, name the manifest, push nothing.
setup desc
if git -C "$L" merge-tree --write-tree origin/develop "$HEAD_SHA" >/dev/null 2>&1; then bad "case 2b setup does not conflict"; fi
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'plugin.json (the branch changed more than its version line)' <<<"$err" \
  && [ "$(remote_head)" = "$HEAD_SHA" ] && worktrees_clean; then
  ok "a manifest conflict over a non-version edit: refused, branch untouched (the edit is not dropped)"
else bad "desc conflict: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi
# 2c. the same, but the edit sits on the version line itself (a hooks key after the version): only the
# version value is set aside, as merge-pr.sh check_review does, so this edit is refused too, not dropped.
setup hooks
if git -C "$L" merge-tree --write-tree origin/develop "$HEAD_SHA" >/dev/null 2>&1; then bad "case 2c setup does not conflict"; fi
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'plugin.json (the branch changed more than its version line)' <<<"$err" \
  && [ "$(remote_head)" = "$HEAD_SHA" ] && worktrees_clean; then
  ok "a manifest conflict over an edit on the version line: refused, branch untouched"
else bad "version-line edit conflict: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 3. a deliberate bump above develop's (a minor release) is kept, not replaced by develop + 1.
setup bump:1.1.0; run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$(git -C "$L" show "$out:.claude-plugin/plugin.json" | ver /dev/stdin)" = 1.1.0 ] \
  && [ "$(git -C "$L" show "$out:.claude-plugin/marketplace.json" | ver /dev/stdin)" = 1.1.0 ]; then
  ok "a head version above develop's is kept (1.1.0)"
else bad "kept bump: rc=$rc out='$out' err=$err"; fi

# 4. a conflict outside the manifests: refuse, name the file, push nothing, leave nothing behind.
setup conflict; run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'a.txt' <<<"$err" && [ "$(remote_head)" = "$HEAD_SHA" ] && worktrees_clean; then
  ok "conflict outside the manifests: refused, names a.txt, branch and worktrees untouched"
else bad "other conflict: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 5. already synced (contains develop, ships 1.0.7): runs the gauntlet on it, prints the head, pushes nothing.
setup none
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b develop "$O" "$w/c"; git -C "$w/c" checkout -q -b feat/x
manifests "$w/c" 1.0.7; commit "$w/c" "synced"; git -C "$w/c" push -q -f origin feat/x
git -C "$L" fetch -q origin; HEAD_SHA=$(git -C "$L" rev-parse origin/feat/x)
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$out" = "$HEAD_SHA" ] && [ "$(remote_head)" = "$HEAD_SHA" ] && worktrees_clean; then
  ok "already synced: prints the head unchanged, no push, no worktree"
else bad "synced: rc=$rc out='$out' err=$err"; fi
if [ "$(gauntlets)" = 1 ] && /usr/bin/grep -q "^head=$HEAD_SHA " "$STUB_DIR/gauntlet.log"; then
  ok "already synced: the full gauntlet still runs on the head (its push only linted it)"
else bad "synced: gauntlet: $(cat "$STUB_DIR/gauntlet.log" 2>&1)"; fi
# 5b. ...a red gauntlet there refuses, prints nothing.
STUB_GAUNTLET_FAIL=1 run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'the gauntlet failed on' <<<"$err" && worktrees_clean; then
  ok "already synced, red gauntlet: refused, nothing on stdout"
else bad "synced red: rc=$rc out='$out' err=$err"; fi
# 5c. ...and a pass cached for its tree skips the run and says so.
mkdir -p "$GAUNTLET_PASS_DIR"; date >"$GAUNTLET_PASS_DIR/$(git -C "$L" rev-parse "$HEAD_SHA^{tree}")"
n0=$(gauntlets)
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$out" = "$HEAD_SHA" ] && [ "$(gauntlets)" = "$n0" ] && /usr/bin/grep -q 'already passed on tree' <<<"$err"; then
  ok "a pass cached for the tree skips the gauntlet and says so on stderr"
else bad "cache hit: rc=$rc out='$out' runs=$(gauntlets)/$n0 err=$err"; fi
GAUNTLET_PASS_CACHE=0 run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$(gauntlets)" = $((n0 + 1)) ]; then ok "GAUNTLET_PASS_CACHE=0 runs it despite the cached pass"; else bad "opt-out: runs=$(gauntlets)/$n0"; fi

# 5e. GH #742: mh/gauntlet success on the head after a green run and after a cached pass, none after a
#     red run; a failed post exits non-zero and prints no sha.
setup none
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$(statuses "$out")" = 1 ] && [ "$(wc -l <"$STUB_DIR/gh.log")" -eq 1 ]; then
  ok "behind, green: one mh/gauntlet success status on the pushed head"
else bad "status green: rc=$rc out='$out' log=$(cat "$STUB_DIR/gh.log" 2>&1)"; fi
new=$out; : >"$STUB_DIR/gh.log"
git -C "$L" fetch -q origin
# A pass dir of its own: trees repeat across cases, and a shared entry would skip later red runs.
mkdir -p "$STUB_DIR/pass"; date >"$STUB_DIR/pass/$(git -C "$L" rev-parse "$new^{tree}")"
GAUNTLET_PASS_DIR="$STUB_DIR/pass" run_sync feat/x "$new"
if [ "$rc" -eq 0 ] && [ "$out" = "$new" ] && /usr/bin/grep -q 'already passed on tree' <<<"$err" && [ "$(statuses "$new")" = 1 ]; then
  ok "already synced, cached pass: the status is posted on the head"
else bad "status cached: rc=$rc out='$out' log=$(cat "$STUB_DIR/gh.log" 2>&1) err=$err"; fi
setup none
STUB_GAUNTLET_FAIL=1 run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ ! -s "$STUB_DIR/gh.log" ]; then ok "red gauntlet: no status posted"; else bad "status red: rc=$rc log=$(cat "$STUB_DIR/gh.log" 2>&1)"; fi
setup none
STUB_STATUS_FAIL=1 run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'could not post the mh/gauntlet status' <<<"$err"; then
  ok "a failed status post exits non-zero and prints no sha to merge"
else bad "status fail: rc=$rc out='$out' err=$err"; fi

# 5f. already synced, but origin's branch is not that head (never pushed there): refused before any
#     status, naming the cause.
setup none
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b develop "$O" "$w/c"; git -C "$w/c" checkout -q -b other
manifests "$w/c" 1.0.7; commit "$w/c" "synced"; git -C "$w/c" push -q origin other
git -C "$L" fetch -q origin; other=$(git -C "$L" rev-parse origin/other)
n0=$(gauntlets)
run_sync feat/x "$other"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'the head was not pushed' <<<"$err" && [ ! -s "$STUB_DIR/gh.log" ] && [ "$(gauntlets)" = "$n0" ]; then
  ok "already synced, head not on origin's branch: refused before the gauntlet, no status, says the head was not pushed"
else bad "unpushed head: rc=$rc out='$out' runs=$(gauntlets)/$n0 log=$(cat "$STUB_DIR/gh.log" 2>&1) err=$err"; fi

# 5g. no gh on PATH (a cloud session): the sync still pushes and prints the head, says no status was
#     posted. NOGH links every PATH tool but gh, so neither the stub nor a real gh is reachable.
NOGH="$ROOT_DIR/nogh"; mkdir -p "$NOGH"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  for f in "$d"/*; do
    b=${f##*/}
    [ "$b" != gh ] && [ -x "$f" ] && [ ! -e "$NOGH/$b" ] && ln -s "$f" "$NOGH/$b"
  done
done
setup none
PATH="$NOGH" run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ -n "$out" ] && [ "$(remote_head)" = "$out" ] && /usr/bin/grep -q 'no gh, so no mh/gauntlet status was posted' <<<"$err" && [ ! -s "$STUB_DIR/gh.log" ]; then
  ok "no gh: pushed and printed the head, said no status was posted"
else bad "no gh: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 5d. behind develop, red gauntlet on the merged tree: nothing is pushed, nothing printed.
setup none
STUB_GAUNTLET_FAIL=1 run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ "$(remote_head)" = "$HEAD_SHA" ] && /usr/bin/grep -q 'the gauntlet failed on' <<<"$err" && worktrees_clean; then
  ok "behind, red gauntlet: refused before the push, branch untouched"
else bad "behind red: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 6. contains develop but ships develop's version: one bump commit, no merge commit.
setup none
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b develop "$O" "$w/c"; git -C "$w/c" checkout -q -b feat/x
echo d >"$w/c/d.txt"; commit "$w/c" "no bump"; git -C "$w/c" push -q -f origin feat/x
git -C "$L" fetch -q origin; HEAD_SHA=$(git -C "$L" rev-parse origin/feat/x)
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$(git -C "$L" rev-parse "$out^")" = "$HEAD_SHA" ] && [ "$(git -C "$L" rev-list --parents -n1 "$out" | wc -w)" -eq 2 ] \
  && [ "$(git -C "$L" show "$out:.claude-plugin/plugin.json" | ver /dev/stdin)" = 1.0.7 ] \
  && /usr/bin/grep -q '^chore: bump mh to 1.0.7' <<<"$(git -C "$L" log -1 --format=%s "$out")"; then
  ok "up to date, same version: a single 'chore: bump mh to 1.0.7' commit on the head"
else bad "bump only: rc=$rc out='$out' err=$err"; fi

# 7b. contains develop, plugin.json bumped but marketplace.json not: the early return must not take it;
# a bump commit brings marketplace.json to plugin.json's 1.0.7.
setup none
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b develop "$O" "$w/c"; git -C "$w/c" checkout -q -b feat/x
sed 's/"version": "1.0.6"/"version": "1.0.7"/' "$w/c/.claude-plugin/plugin.json" >"$w/c/p.tmp" && mv "$w/c/p.tmp" "$w/c/.claude-plugin/plugin.json"
commit "$w/c" "half bump"; git -C "$w/c" push -q -f origin feat/x
git -C "$L" fetch -q origin; HEAD_SHA=$(git -C "$L" rev-parse origin/feat/x)
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -eq 0 ] && [ "$out" != "$HEAD_SHA" ] && [ "$(git -C "$L" show "$out:.claude-plugin/marketplace.json" | ver /dev/stdin)" = 1.0.7 ] \
  && [ "$(git -C "$L" show "$out:.claude-plugin/plugin.json" | ver /dev/stdin)" = 1.0.7 ]; then
  ok "manifests disagree on an up-to-date head: bumped so both say 1.0.7"
else bad "half bump: rc=$rc out='$out' err=$err"; fi

# 8. someone pushed to the branch after the head was read: the push is not a fast-forward, refuse.
setup none
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b feat/x "$O" "$w/c"
echo e >"$w/c/e.txt"; commit "$w/c" "late push"; git -C "$w/c" push -q origin feat/x
late=$(git -C "$w/c" rev-parse HEAD)
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ "$(remote_head)" = "$late" ] && /usr/bin/grep -q 'push to origin/feat/x failed' <<<"$err" && worktrees_clean; then
  ok "branch moved after the head was read: refused, the late push stays"
else bad "moved branch: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 8b. the branch was rewound to an ancestor of the head after it was read: a plain fast-forward push
# would re-push the dropped commits; the lease on the head refuses.
setup none
base=$(git -C "$L" rev-parse "$HEAD_SHA^")
w=$(mktemp -d "$ROOT_DIR/w.XXXXXX"); git clone -q -b feat/x "$O" "$w/c"; git -C "$w/c" push -q -f origin "$base:refs/heads/feat/x"
run_sync feat/x "$HEAD_SHA"
if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ "$(remote_head)" = "$base" ] && worktrees_clean; then
  ok "branch rewound after the head was read: refused by the lease, the rewind stays"
else bad "rewound branch: rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 8c. the push lands but git exits 141 (GitHub dropped the idle SSH connection after the gauntlet): the
# ls-remote check sees the new head on origin, so the sync counts.
setup none
gw=$(mktemp -d "$ROOT_DIR/gitwrap.XXXXXX")
printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\nfor a in "$@"; do [ "$a" = push ] && exit 141; done\nexit $rc\n' "$(command -v git)" >"$gw/git"
chmod +x "$gw/git"
out=$(cd "$L" && PATH="$gw:$PATH" bash "$SCRIPT" feat/x "$HEAD_SHA" 2>"$ROOT_DIR/err"); rc=$?; err=$(cat "$ROOT_DIR/err")
if [ "$rc" -eq 0 ] && [ -n "$out" ] && [ "$(remote_head)" = "$out" ] && /usr/bin/grep -q 'git push exited 141 but origin has' <<<"$err"; then
  ok "push exits 141 after landing: ls-remote finds the head, the sync counts"
else bad "landed push rc=$rc out='$out' remote=$(remote_head) err=$err"; fi

# 9. usage: both arguments are required.
out=$(bash "$SCRIPT" feat/x 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q usage <<<"$out"; then ok "missing head argument: usage, exit 2"; else bad "usage: rc=$rc out=$out"; fi

safe_tmp_delete "$ROOT_DIR"
echo "sync-pr-head: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
