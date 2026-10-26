#!/usr/bin/env bash
# test-merge-pr.sh — GH #450: scripts/merge-pr.sh brings a develop PR up to date, cuts its version and
# merges it pinned with --match-head-commit. PRs no longer bump the version (2026-10-25: every peer merge
# re-conflicted every open PR on the two manifest lines): the script merges origin/develop into the PR
# branch, writes develop's version + 1, and pushes from the caller's checkout so the pre-push gauntlet runs
# on the exact tree that merges, all under a per-user merge lock. It also needs a last "Fresh-context
# review: MERGE @ <sha>" comment whose <sha> is the head or an ancestor followed only by develop merges
# and manifest-only commits (#569-#576 and #611 merged with FIX FIRST reviews open).
# Real git: each case builds a bare origin, a seed clone that plays the peers, and a work clone on the
# PR branch whose pre-push hook is a recorder. Only gh and uptime are stubbed; never touches GitHub.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../scripts/merge-pr.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && trash "$1" 2>/dev/null; return 0; }

# The fixture's git must not read the operator's config (hooks, signing) or a caller's lock state.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GAUNTLET_LOCK_DIR MH_GAUNTLET_LOCK_OWNER GIT_SSH_COMMAND
# A git hook exports GIT_DIR; the fixture's git commits and pushes would then target the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

echo "=== merge-pr.sh syncs, cuts the version, pushes and merges (GH #450) ==="

T=$(mktemp -d)
if [ -z "$T" ]; then echo "mktemp -d failed" >&2; exit 1; fi
STUB="$T/stub"
mkdir -p "$STUB/hooks"

# gh: the PR is #451 on feat/x; its head is whatever origin's feat/x holds (STUB_ORIGIN), like GitHub.
#   `pr view --json headRefOid,baseRefName,headRefName` prints "<head> STUB_BASE feat/x" (nothing when
#   STUB_EMPTY is set); `--json baseRefName` prints STUB_BASE2, else STUB_BASE, else develop (the re-read
#   just before the merge); `pr merge` refuses unless --match-head-commit equals origin's feat/x, or when
#   STUB_MERGE_REFUSE is set; `api --paginate .../comments` applies the script's own --jq to
#   STUB_COMMENTS_JSON (STUB_COMMENTS_JSON2 from the second read on; STUB_API_FAIL fails it).
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
tip() { git --git-dir="$STUB_ORIGIN" rev-parse refs/heads/feat/x; }
case "$*" in
  *"pr merge"*)
    want=""; prev=""
    for a in "$@"; do [ "$prev" = "--match-head-commit" ] && want="$a"; prev="$a"; done
    [ -z "${STUB_MERGE_REFUSE:-}" ] && [ "$want" = "$(tip)" ] || { echo "head branch was modified" >&2; exit 1; }
    exit 0 ;;
  *headRefOid,baseRefName,headRefName*) [ -n "${STUB_EMPTY:-}" ] || echo "$(tip) ${STUB_BASE:-develop} feat/x" ;;
  *"--json headRefOid "*) tip ;;
  *baseRefName*) echo "${STUB_BASE2:-${STUB_BASE:-develop}}" ;;
  *mergeCommit*) echo "mergesha000" ;;
  *"api --paginate"*comments*)
    [ -z "${STUB_API_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
    n=0; [ ! -f "$STUB_DIR/api" ] || n=$(cat "$STUB_DIR/api"); n=$((n + 1)); echo "$n" >"$STUB_DIR/api"
    json="$STUB_COMMENTS_JSON"; if [ "$n" -gt 1 ]; then json="${STUB_COMMENTS_JSON2-$STUB_COMMENTS_JSON}"; fi
    q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
    printf '%s' "$json" | jq -r "$q" ;;
  *) exit 2 ;;
esac
EOF
# uptime runs in the work clone after the lock is taken; STUB_DIRTY_DURING has it leave a stray file
# there, as a caller still editing the checkout during the wait would.
cat >"$STUB/uptime" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_DIRTY_DURING:-}" ] || echo stray >stray.txt
echo "10:00  up 1 day, 2 users, load averages: $STUB_LOAD 2.00 2.00"
EOF
# A pre-commit hook that fails when STUB_PRECOMMIT_FAIL is set (a red lint on the sync or bump commit).
cat >"$STUB/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_PRECOMMIT_FAIL:-}" ] || { echo "pre-commit: red" >&2; exit 1; }
exit 0
EOF
# The work clone's pre-push hook stands in for the gauntlet: it records the tree it ran on and the lock
# variables it saw, fails when STUB_PREPUSH_FAIL is set, and on its first call with STUB_PREPUSH_PEER
# set lands a peer merge on origin's develop (develop moving while the gauntlet runs).
cat >"$STUB/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
n=0; [ ! -f "$STUB_DIR/prepush.n" ] || n=$(cat "$STUB_DIR/prepush.n"); n=$((n + 1)); echo "$n" >"$STUB_DIR/prepush.n"
{
  echo "head=$(git rev-parse HEAD)"
  echo "dirty=$(git status --porcelain | tr '\n' ' ')"
  echo "lockdir=${GAUNTLET_LOCK_DIR-} owner=${MH_GAUNTLET_LOCK_OWNER-}"
  if [ -d "$MERGE_PR_LOCK_DIR" ]; then echo "mergelock=held"; else echo "mergelock=free"; fi
  echo "ssh=${GIT_SSH_COMMAND-}"
} >>"$STUB_DIR/prepush.log"
[ -z "${STUB_PREPUSH_FAIL:-}" ] || { echo "gauntlet: red" >&2; exit 1; }
[ -z "${STUB_PREPUSH_DIRTY:-}" ] || echo edit >>b.txt
if [ -n "${STUB_PREPUSH_PEER:-}" ] && [ "$n" -eq 1 ]; then
  (unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; bash "$STUB_PEER")
fi
exit 0
EOF
# The peer that lands during the gauntlet (STUB_PREPUSH_PEER): one develop commit with the next version,
# made in the seed clone (STUB_SEED).
cat >"$STUB/peer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$STUB_SEED"
git checkout -q develop
git pull -q origin develop
v=$(awk -F'"' '/"version"/ && !s { print $4; s = 1 }' .claude-plugin/plugin.json)
n=$(echo "$v" | awk -F. '{ print $1 "." $2 "." $3 + 1 }')
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  new=$(awk -v v="$v" -v n="$n" '{ i = index($0, "\"version\": \"" v "\""); if (i) $0 = substr($0, 1, i - 1) "\"version\": \"" n "\"" substr($0, i + 13 + length(v)) } { print }' "$f")
  printf '%s\n' "$new" >"$f"
done
echo peer >>c.txt
git commit -qam peer-during-gauntlet
git push -q origin develop
EOF
chmod +x "$STUB/gh" "$STUB/uptime" "$STUB/hooks/pre-push" "$STUB/hooks/pre-commit"

PLUGIN=.claude-plugin/plugin.json
MARKET=.claude-plugin/marketplace.json
# write_manifests <dir> <plugin version> <marketplace version> <marketplace description>; the
# description sits on the line after the version, so a version conflict takes it into the same hunk.
write_manifests() {
  mkdir -p "$1/.claude-plugin"
  printf '{\n  "name": "mh",\n  "version": "%s"\n}\n' "$2" >"$1/$PLUGIN"
  printf '{\n  "name": "wasikarn",\n  "plugins": [\n    {\n      "name": "mh",\n      "version": "%s",\n      "description": "%s"\n    }\n  ]\n}\n' "$3" "$4" >"$1/$MARKET"
}
ver_of() { awk -F'"' '/"version"/ && !seen { print $4; seen = 1 }' "$1"; }
desc_of() { awk -F'"' '/"description"/ { print $4 }' "$1"; }

# setup [base version]: a fresh origin whose develop holds both manifests and a.txt b.txt c.txt, and a
# feat/x branch with one feature commit ($FEATURE). Sets F, the case's fixture dir.
setup() {
  local v="${1:-1.1.1}"
  F=$(mktemp -d "$T/case.XXXXXX")
  git init -q --bare -b develop "$F/origin.git"
  git clone -q "$F/origin.git" "$F/seed" 2>/dev/null
  git -C "$F/seed" checkout -q -b develop
  write_manifests "$F/seed" "$v" "$v" "base desc"
  printf 'a\n' >"$F/seed/a.txt"; printf 'b\n' >"$F/seed/b.txt"; printf 'c\n' >"$F/seed/c.txt"
  git -C "$F/seed" add -- "$PLUGIN" "$MARKET" a.txt b.txt c.txt
  git -C "$F/seed" commit -qm base
  git -C "$F/seed" push -q origin develop
  git -C "$F/seed" checkout -q -b feat/x
  printf 'feature\n' >>"$F/seed/b.txt"
  git -C "$F/seed" commit -qam feature
  git -C "$F/seed" push -q origin feat/x
  FEATURE=$(git -C "$F/seed" rev-parse HEAD)
  git -C "$F/seed" checkout -q develop
}
# on <branch> <message> <command...>: run a change in the seed clone on <branch>, commit it, push it.
on() {
  local b=$1 m=$2; shift 2
  git -C "$F/seed" checkout -q "$b"
  (cd "$F/seed" && "$@")
  git -C "$F/seed" commit -qam "$m"
  git -C "$F/seed" push -q origin "$b"
  git -C "$F/seed" checkout -q develop
}
set_ver() { write_manifests . "$1" "${2:-$1}" "$(desc_of "$MARKET")"; }
set_desc() { write_manifests . "$(ver_of "$PLUGIN")" "$(ver_of "$MARKET")" "$1"; }
append() { printf '%s\n' "$2" >>"$1"; }
# work: the PR's own checkout, on feat/x, with the recording pre-push hook.
work() {
  git clone -q -b feat/x "$F/origin.git" "$F/work"
  git -C "$F/work" config core.hooksPath "$STUB/hooks"
}
remote_tip() { git --git-dir="$F/origin.git" rev-parse "refs/heads/$1"; }
# verdict <text>: one PR comment whose body carries the line "## Fresh-context review: <text>".
verdict() { jq -nc --arg v "$1" '[{created_at: "2026-10-25T00:00:00Z", body: ("Some text.\n## Fresh-context review: " + $v + "\nmore")}]'; }
comments() { jq -sc 'add' <<<"$*"; }

# run: merge-pr.sh 451 from the work clone; sets out, rc. The default review is MERGE @ origin's feat/x.
# Extra stub env (STUB_BASE, STUB_BASE2, STUB_EMPTY, STUB_LOAD, STUB_COMMENTS_JSON2, STUB_API_FAIL,
# STUB_MERGE_REFUSE, STUB_PREPUSH_FAIL, STUB_PREPUSH_PEER) comes from the caller's environment.
run() {
  [ -d "$F/work" ] || work
  : >"$F/calls.log"
  out=$(cd "$F/work" && PATH="$STUB:$PATH" STUB_LOG="$F/calls.log" STUB_DIR="$F" \
    STUB_ORIGIN="$F/origin.git" STUB_PEER="$STUB/peer.sh" STUB_SEED="$F/seed" STUB_LOAD="${STUB_LOAD:-1.50}" \
    STUB_COMMENTS_JSON="${STUB_COMMENTS_JSON-$(verdict "MERGE @ $(remote_tip feat/x)")}" \
    MERGE_PR_LOAD_WAIT_SECS=0 MERGE_PR_LOAD_MAX=4 MERGE_PR_LOCK_DIR="$F/merge.lock" MERGE_PR_LOCK_WAIT_SECS=0 \
    bash "$SCRIPT" 451 2>&1)
  rc=$?
}
merged() { /usr/bin/grep -q '^gh pr merge' "$F/calls.log"; }
pushes() { if [ -f "$F/prepush.n" ]; then cat "$F/prepush.n"; else echo 0; fi; }
w() { git -C "$F/work" "$@"; }

# merges <label>: the last run() exited 0, merged pinned to origin's feat/x, which is the local HEAD,
# printed the merge sha last, freed the lock, and left the checkout clean with no open merge.
merges() {
  local tip; tip=$(remote_tip feat/x)
  if [ "$rc" -eq 0 ]; then ok "$1 exits 0"; else bad "$1 rc=$rc: $out"; fi
  if /usr/bin/grep -q "^gh pr merge 451 --merge --match-head-commit $tip\$" "$F/calls.log"; then
    ok "$1 merges pinned to origin's head"
  else bad "$1 merge not pinned to $tip: $(cat "$F/calls.log")"; fi
  if [ "$(w rev-parse HEAD)" = "$tip" ]; then ok "$1 pushed the local HEAD"; else bad "$1 local HEAD is not origin's feat/x"; fi
  if [ "$(printf '%s\n' "$out" | tail -n 1)" = "mergesha000" ]; then ok "$1 prints the merge sha last"; else bad "$1 last line: <$out>"; fi
  if [ ! -d "$F/merge.lock" ]; then ok "$1 frees the merge lock"; else bad "$1 left the merge lock behind"; fi
  if [ -z "$(w status --porcelain)" ] && ! w rev-parse -q --verify MERGE_HEAD >/dev/null; then
    ok "$1 leaves the checkout clean"
  else bad "$1 left the checkout dirty: $(w status --porcelain)"; fi
}
# refuses <label> <message-pattern>: the last run() exited non-zero, never reached gh pr merge, said why,
# freed the lock, and left no open merge or edited manifest behind.
refuses() {
  if [ "$rc" -ne 0 ]; then ok "$1 exits non-zero (rc=$rc)"; else bad "$1 exited 0"; fi
  if merged; then bad "$1 still reached gh pr merge"; else ok "$1 never calls gh pr merge"; fi
  if /usr/bin/grep -q -- "$2" <<<"$out"; then ok "$1 message matches '$2'"; else bad "$1: no '$2' in: $out"; fi
  if [ ! -d "$F/merge.lock" ]; then ok "$1 frees the merge lock"; else bad "$1 left the merge lock behind"; fi
  if [ -z "$(w status --porcelain)" ] && ! w rev-parse -q --verify MERGE_HEAD >/dev/null; then
    ok "$1 leaves the checkout clean"
  else bad "$1 left the checkout dirty: $(w status --porcelain)"; fi
}
# untouched <label>: the refusal wrote nothing: HEAD is still the PR head and no push ran.
untouched() {
  if [ "$(w rev-parse HEAD)" = "$(remote_tip feat/x)" ] && [ "$(pushes)" = 0 ]; then
    ok "$1 commits and pushes nothing"
  else bad "$1 changed the branch (HEAD $(w rev-parse HEAD), $(pushes) pushes)"; fi
}

# 1. behind develop, PR never touched the version: one merge commit that syncs and bumps develop + 1, pushed
#    from a clean tree with the merge lock kept out of the hook's environment, then merged.
setup; on develop "peer 1.1.2" set_ver 1.1.2
run
merges "behind PR"
if [ "$(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")" = "1.1.3 1.1.3" ]; then ok "both manifests cut to develop + 1"; else bad "versions: $(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")"; fi
if [ "$(w log -1 --format=%s)" = "Merge origin/develop into feat/x; bump mh to 1.1.3" ] && [ "$(w rev-list --count --merges "$FEATURE..HEAD")" = 1 ] && [ "$(w rev-list --count "$FEATURE..HEAD")" = 2 ]; then
  ok "sync and bump are one merge commit"
else bad "commit shape: $(w log --oneline "$FEATURE..HEAD")"; fi
if /usr/bin/grep -qx "head=$(remote_tip feat/x)" "$F/prepush.log" && /usr/bin/grep -qx "dirty=" "$F/prepush.log"; then
  ok "the pre-push gauntlet ran on the clean tree that merges"
else bad "pre-push saw: $(cat "$F/prepush.log")"; fi
if /usr/bin/grep -qx "lockdir= owner=" "$F/prepush.log"; then ok "the merge lock does not leak into the pre-push hook"; else bad "hook env: $(cat "$F/prepush.log")"; fi
if /usr/bin/grep -qx "mergelock=held" "$F/prepush.log"; then ok "the merge lock is held while the gauntlet runs"; else bad "lock during push: $(cat "$F/prepush.log")"; fi
if /usr/bin/grep -qx "ssh=ssh -o ServerAliveInterval=30" "$F/prepush.log"; then ok "the push keeps its SSH connection alive through the gauntlet"; else bad "push ssh: $(cat "$F/prepush.log")"; fi
if w merge-base --is-ancestor "$(remote_tip develop)" HEAD; then ok "the merged head contains origin/develop"; else bad "head misses develop"; fi

# 2. up to date with develop, same version: a plain bump commit on the PR head.
setup
run
merges "up-to-date PR"
if [ "$(w log -1 --format=%s)" = "chore: bump mh to 1.1.2" ] && [ "$(w rev-parse HEAD^)" = "$FEATURE" ]; then
  ok "a plain bump commit on the PR head"
else bad "commit shape: $(w log --oneline -3)"; fi

# 3. an older PR already above develop and up to date: no commit and no push, but the script runs the
#    pre-push hook itself on that head (its author may have pushed with hooks off), then merges.
setup 1.1.99; on feat/x "self-bump" set_ver 1.1.100
before=$(remote_tip feat/x)
run
merges "self-bumped PR"
if [ "$(remote_tip feat/x)" = "$before" ]; then ok "a head above develop is kept (1.1.100 over 1.1.99)"; else bad "self-bumped PR was rewritten"; fi
if [ "$(pushes)" = 1 ] && /usr/bin/grep -qx "head=$before" "$F/prepush.log"; then ok "the gauntlet runs on a head the script did not push"; else bad "no gauntlet on an unpushed head: $(pushes)"; fi
# ...and refuses when that gauntlet is red, or when there is no hook to run it.
setup 1.1.99; on feat/x "self-bump" set_ver 1.1.100
STUB_PREPUSH_FAIL=1 run
refuses "red gauntlet on an unpushed head" "the pre-push gauntlet failed on"
setup 1.1.99; on feat/x "self-bump" set_ver 1.1.100; work; w config --unset core.hooksPath
run
refuses "no pre-push hook" "no executable pre-push hook"

# 3b. versions order per number: develop at 1.1.99 is cut to 1.1.100, not 1.1.910.
setup 1.1.99; on develop "peer" append c.txt peer
run
merges "1.1.99 develop"
if [ "$(ver_of "$F/work/$PLUGIN")" = "1.1.100" ]; then ok "1.1.99 + 1 is 1.1.100"; else bad "cut $(ver_of "$F/work/$PLUGIN")"; fi

# 4. an older PR that bumped itself conflicts with develop on the version line: merged with the PR's
#    other manifest edit (the description, in the same hunk) kept, cut above develop.
setup; on feat/x "self-bump" set_ver 1.1.2; on feat/x "desc" set_desc "PR desc"; on develop "peers" set_ver 1.1.3
run
merges "version-only conflict"
if [ "$(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")" = "1.1.4 1.1.4" ] && [ "$(desc_of "$F/work/$MARKET")" = "PR desc" ]; then
  ok "version conflict resolved, PR's description kept"
else bad "manifests: $(cat "$F/work/$MARKET")"; fi

# 4b. a deliberate minor bump in the PR survives the version conflict: 1.2.0 over develop's 1.1.2.
setup; on feat/x "minor" set_ver 1.2.0; on develop "peer" set_ver 1.1.2
run
merges "deliberate minor bump"
if [ "$(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")" = "1.2.0 1.2.0" ]; then ok "the PR's higher version is kept"; else bad "minor bump became $(ver_of "$F/work/$PLUGIN")"; fi

# 5. a real conflict in another file: refuse, nothing committed or pushed.
setup; on feat/x "pr a" append a.txt pr; on develop "dev a" append a.txt dev
run
refuses "conflict in a.txt" "conflicts in a.txt"
untouched "conflict in a.txt"

# 6. a manifest conflict beyond the version line: refuse.
setup; on feat/x "pr desc" set_desc "PR desc"; on feat/x "bump" set_ver 1.1.2; on develop "dev desc" set_desc "dev desc"; on develop "dev bump" set_ver 1.1.3
run
refuses "manifest conflict beyond the version" "still conflicts"
untouched "manifest conflict beyond the version"

# 7. develop moves while the gauntlet runs (a merge from outside the lock): sync again, push again, merge.
setup
STUB_PREPUSH_PEER=1 run
merges "develop moved during the gauntlet"
if [ "$(pushes)" = 2 ] && /usr/bin/grep -q "round 2 of 3" <<<"$out"; then ok "a second round synced and pushed again"; else bad "rounds: $(pushes) pushes: $out"; fi
if [ "$(ver_of "$F/work/$PLUGIN")" = "1.1.3" ] && w merge-base --is-ancestor "$(remote_tip develop)" HEAD; then
  ok "the second round cut above the peer's 1.1.2"
else bad "after round 2: $(ver_of "$F/work/$PLUGIN")"; fi

# 8. a red gauntlet: the push does not land; refuse and keep the sync commit. A rerun pushes that commit.
setup; on develop "peer 1.1.2" set_ver 1.1.2
STUB_PREPUSH_FAIL=1 run
if [ "$rc" -ne 0 ] && ! merged && /usr/bin/grep -q "did not land" <<<"$out"; then ok "red gauntlet refuses"; else bad "red gauntlet rc=$rc: $out"; fi
synced=$(w rev-parse HEAD)
if [ "$synced" != "$(remote_tip feat/x)" ] && [ -z "$(w status --porcelain)" ]; then ok "the sync commit stays local and the tree clean"; else bad "after a red gauntlet: $(w status --porcelain)"; fi
run
merges "rerun after a red gauntlet"
if [ "$(remote_tip feat/x)" = "$synced" ]; then ok "the rerun pushes the same commit, no second bump"; else bad "rerun made another commit"; fi

# 9. GitHub refuses the merge (a push after the check): fail, print no merge sha.
setup
STUB_MERGE_REFUSE=1 run
if [ "$rc" -ne 0 ] && ! /usr/bin/grep -q mergesha000 <<<"$out"; then ok "a refused merge fails without a merge sha"; else bad "refused merge rc=$rc: $out"; fi

# 10. the checkout is not the PR branch, is dirty, or is behind the PR head: refuse before writing.
setup; work; w checkout -q -b other
run
refuses "wrong branch" "checkout of PR 451's branch feat/x"
setup; work; printf 'x\n' >"$F/work/stray.txt"
run
if [ "$rc" -ne 0 ] && /usr/bin/grep -q "untracked" <<<"$out" && ! merged && [ ! -d "$F/merge.lock" ]; then ok "an untracked file refuses"; else bad "untracked rc=$rc: $out"; fi
untouched "untracked file"

# 10b. the caller edits the checkout during the lock or load wait: refuse before syncing or pushing.
setup; on develop "peer" set_ver 1.1.2
STUB_DIRTY_DURING=1 run
if [ "$rc" -ne 0 ] && /usr/bin/grep -q "after the lock and load waits" <<<"$out" && ! merged && [ ! -d "$F/merge.lock" ]; then
  ok "an edit during the wait refuses"
else bad "edit during the wait rc=$rc: $out"; fi
untouched "edit during the wait"

# 10c. the checkout changes while the gauntlet runs: its result does not cover the tree, so no merge.
setup
STUB_PREPUSH_DIRTY=1 run
if [ "$rc" -ne 0 ] && /usr/bin/grep -q "changed while the pre-push gauntlet ran" <<<"$out" && ! merged && [ ! -d "$F/merge.lock" ]; then
  ok "an edit during the gauntlet refuses the merge"
else bad "edit during the gauntlet rc=$rc: $out"; fi
# The push already landed; a rerun on the cleaned tree must run the gauntlet again, not merge on trust.
w restore b.txt
run
merges "rerun after an edit during the gauntlet"
if [ "$(pushes)" = 2 ]; then ok "the rerun runs the gauntlet again"; else bad "rerun gauntlets: $(pushes)"; fi

# 10d. a red pre-commit hook on the sync or the bump commit: refuse, abort the merge, restore the manifests.
setup; on develop "peer" set_ver 1.1.2
STUB_PRECOMMIT_FAIL=1 run
refuses "red pre-commit on the sync" "git commit of the sync failed"
untouched "red pre-commit on the sync"
setup
STUB_PRECOMMIT_FAIL=1 run
refuses "red pre-commit on the bump" "git commit of the version bump failed"
untouched "red pre-commit on the bump"
setup; work; on feat/x "pushed elsewhere" append b.txt more
run
refuses "local branch behind the PR head" "pull the branch first"

# 11. base checks and an empty gh answer.
setup; STUB_BASE=main run
refuses "non-develop base" "not develop"
setup; STUB_BASE2=main run
refuses "retargeted base" "base changed"
setup; STUB_EMPTY=1 run
refuses "empty gh output" "could not read the head sha"

# 12. load stays high: fail with the figure, before writing anything.
setup; on develop "peer" set_ver 1.1.2
STUB_LOAD=7.25 run
refuses "high load" "7.25"
untouched "high load"

# 13. another merge-pr.sh holds the lock past the wait: refuse, leave its lock alone.
setup; mkdir "$F/merge.lock"; echo "$$" >"$F/merge.lock/pid"
run
if [ "$rc" -ne 0 ] && /usr/bin/grep -q "could not take the merge lock" <<<"$out" && ! merged && [ "$(cat "$F/merge.lock/pid")" = "$$" ]; then
  ok "a held merge lock refuses and stays with its owner"
else bad "held lock rc=$rc: $out"; fi
safe_trash "$F/merge.lock"

# 14. develop's version cannot be ordered, or its manifest is missing: refuse, nothing left behind.
setup 1.1.196-rc1; on develop "peer" append c.txt peer
run
refuses "non-numeric develop version" "not X.Y.Z"
setup 01.1.5
run
refuses "leading-zero version" "not X.Y.Z"
setup; on develop "drop manifest" git rm -q "$PLUGIN"
run
refuses "missing develop manifest" "cannot read"
untouched "missing develop manifest"

# 15. two manifests that disagree at the head are cut to one number above develop.
setup; on feat/x "mismatch" set_ver 1.1.5 1.1.9
run
merges "manifest mismatch"
if [ "$(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")" = "1.1.2 1.1.2" ]; then ok "mismatched manifests cut to one number"; else bad "mismatch: $(ver_of "$F/work/$PLUGIN") $(ver_of "$F/work/$MARKET")"; fi

# 16. review verdict (2026-10-25). No verdict comment at all: refuse before the load wait or any write.
setup; STUB_LOAD=7.25 STUB_COMMENTS_JSON='[{"created_at":"2026-10-25T00:00:00Z","body":"A fresh-context review of this PR is in progress."}]' run
refuses "no review verdict" "no \"Fresh-context review: MERGE @ <sha>\""
if /usr/bin/grep -q 'load' <<<"$out"; then bad "no verdict refused only after the load wait: $out"; else ok "no verdict is refused before the load wait"; fi
untouched "no review verdict"

# 16b. the latest verdict is FIX FIRST, even with an earlier MERGE: refuse and name it.
setup; STUB_COMMENTS_JSON=$(comments "$(verdict "MERGE @ $FEATURE")" "$(verdict 'FIX FIRST')") run
refuses "latest verdict FIX FIRST" "is FIX FIRST, not MERGE"

# 16c. FIX FIRST then a later MERGE on the head (a re-review after the fix): merges.
setup; STUB_COMMENTS_JSON=$(comments "$(verdict 'FIX FIRST')" "$(verdict "MERGE @ $FEATURE")") run
merges "FIX FIRST then MERGE"

# 16d. a substantive commit after the reviewed sha: refuse.
setup; on feat/x "after review" append b.txt late
STUB_COMMENTS_JSON=$(verdict "MERGE @ $FEATURE") run
refuses "a change after the reviewed sha" "touches more than the manifests"

# 16e. a manifest-only commit after the reviewed sha (an older PR's own bump) keeps the review.
setup; on feat/x "self-bump" set_ver 1.1.2
STUB_COMMENTS_JSON=$(verdict "MERGE @ $FEATURE") run
merges "a version bump after the review"

# 16f. a lower-case, bold verdict with a backticked sha and trailing words reads as MERGE; CLOSE refuses.
setup; STUB_COMMENTS_JSON="[{\"created_at\":\"2026-10-25T00:00:00Z\",\"body\":\"## **Fresh-context review: merge** @ \`${FEATURE:0:7}\` after re-sync\"}]" run
merges "a styled MERGE verdict"
setup; STUB_COMMENTS_JSON=$(verdict 'CLOSE') run
refuses "CLOSE verdict" "is CLOSE"

# 16g. a FIX FIRST posted while the script runs: the re-check before the push refuses.
setup; STUB_COMMENTS_JSON2=$(comments "$(verdict "MERGE @ $FEATURE")" "$(verdict 'FIX FIRST')") run
refuses "FIX FIRST posted during the run" "is FIX FIRST"
if [ "$(pushes)" = 0 ]; then ok "a late FIX FIRST stops the push"; else bad "pushed despite a late FIX FIRST"; fi

# 16h. the comments cannot be read: refuse, do not treat it as "no verdict needed".
setup; STUB_API_FAIL=1 run
refuses "unreadable comments" "could not read the comments"

# 16i. a MERGE that names no reviewed commit, or one not in the head's history: refuse.
setup; STUB_COMMENTS_JSON=$(verdict 'MERGE') run
refuses "MERGE without a sha" "names no reviewed commit"
setup; STUB_COMMENTS_JSON=$(verdict 'MERGE @ deadbeef1') run
refuses "reviewed sha not an ancestor" "not in the head's history"

# 16j. a verdict line inside a code fence does not count.
setup; STUB_COMMENTS_JSON="[{\"created_at\":\"2026-10-25T00:00:00Z\",\"body\":\"\`\`\`\nFresh-context review: MERGE @ $FEATURE\n\`\`\`\n## Fresh-context review: FIX FIRST\"}]" run
refuses "fenced MERGE before a real FIX FIRST" "is FIX FIRST"
setup; STUB_COMMENTS_JSON="[{\"created_at\":\"2026-10-25T00:00:00Z\",\"body\":\"~~~\nFresh-context review: MERGE @ $FEATURE\n~~~\"}]" run
refuses "only a fenced MERGE" "no \"Fresh-context review"

# 17. no PR argument: usage error.
out=$(PATH="$STUB:$PATH" bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "missing PR argument exits 2"; else bad "missing PR argument rc=$rc"; fi

safe_trash "$T"
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
