#!/usr/bin/env bash
# test-merge-pr.sh — GH #450: scripts/merge-pr.sh merges only a PR whose head
# contains the origin/develop tip, pinned with --match-head-commit, and whose two manifests
# agree on a version above origin/develop's (both checked before and after the load wait;
# #492/#493, #496/#497 cut the same number). Stubs gh,
# git and uptime on PATH; never touches GitHub. Each failing case also checks
# that `gh pr merge` was never reached (or, for a head mismatch, that it was
# reached with the checked sha and its refusal propagated). It also needs a last "Fresh-context review:
# MERGE @ <sha>" comment whose <sha> is the head or an ancestor followed only by develop merges and
# manifest-only commits (2026-10-25: #569-#576 and #611 merged with FIX FIRST reviews open); the gh stub
# runs the script's own jq on fake comments. Branches do not bump: a head that is behind develop or
# does not ship a version above it is handed to the sync script (stubbed here; scripts/sync-pr-head.sh
# is tested on real repos by test-sync-pr-head.sh) after the load wait, round after round while develop
# keeps moving, and the merge is pinned to the synced head.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../scripts/merge-pr.sh"
pass=0; fail=0
# An exported opt-out would turn every same-version refusal case into a merge; cases set it per call.
unset MERGE_PR_ALLOW_SAME_VERSION
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && trash "$1" 2>/dev/null; return 0; }

echo "=== merge-pr.sh requires an up-to-date head (GH #450) ==="

STUB=$(mktemp -d)
if [ -z "$STUB" ]; then echo "mktemp -d failed" >&2; exit 1; fi
LOG="$STUB/calls.log"

# gh: `pr view --json headRefOid,baseRefName` prints "STUB_HEAD STUB_BASE" (nothing when
# STUB_EMPTY is set); `pr view --json baseRefName` prints STUB_BASE2, else STUB_BASE, else
# develop (the re-read just before the merge); `pr merge` refuses unless
# --match-head-commit equals STUB_REMOTE_HEAD (GitHub's real behaviour);
# `pr view --json mergeCommit` prints the merge sha.
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$*" in
  *"pr merge"*)
    want=""; prev=""
    for a in "$@"; do [ "$prev" = "--match-head-commit" ] && want="$a"; prev="$a"; done
    [ "$want" = "$STUB_REMOTE_HEAD" ] || { echo "head branch was modified" >&2; exit 1; }
    exit 0 ;;
  *headRefOid,baseRefName*) [ -n "${STUB_EMPTY:-}" ] || echo "$STUB_HEAD ${STUB_BASE:-develop}" ;;
  *headRefName,isCrossRepository*) echo "${STUB_BRANCH-feat/x} ${STUB_CROSS:-false}" ;;
  *baseRefName*) echo "${STUB_BASE2:-${STUB_BASE:-develop}}" ;;
  *mergeCommit*) echo "mergesha000" ;;
  *"api --paginate"*comments*)
    # Apply the script's --jq to STUB_COMMENTS_JSON (STUB_COMMENTS_JSON2 from the second read on), so
    # the real expression is what the test exercises. STUB_API_FAIL makes the call fail.
    [ -z "${STUB_API_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
    n=0; [ ! -f "$STUB_DIR/api" ] || n=$(cat "$STUB_DIR/api"); n=$((n + 1)); echo "$n" >"$STUB_DIR/api"
    json="$STUB_COMMENTS_JSON"; if [ "$n" -gt 1 ]; then json="${STUB_COMMENTS_JSON2-$STUB_COMMENTS_JSON}"; fi
    q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
    printf '%s' "$json" | jq -r "$q" ;;
  *) exit 2 ;;
esac
EOF
# git: per-subcommand call counters live in files under STUB_DIR (reset by run()), so a case
# can change what the Nth call returns, i.e. what happened while the script waited for load.
#   fetch: exits 1 on its second call when STUB_FETCH2_FAIL is set, else 0.
#   merge-base --is-ancestor: for a synced head syncsha<n>, 0 when n >= STUB_SYNC_OK_FROM (default 1:
#     the first sync's head is up to date) else 1; for the PR head, STUB_ANCESTOR on call 1,
#     STUB_ANCESTOR2 (default STUB_ANCESTOR) after.
#   show <ref>:<manifest>: prints a manifest whose version is STUB_HEAD_VER (PR head,
#     plugin.json), STUB_HEAD_MKT_VER (PR head, marketplace.json, default STUB_HEAD_VER) or
#     STUB_DEV_VER (origin/develop; STUB_DEV_VER2 from its second read on, default STUB_DEV_VER).
#     STUB_SHOW_FAIL makes every show fail like a missing path. A synced head (syncsha<n>) ships
#     STUB_SYNC_VER (default 99.0.0, above any develop version here).
cat >"$STUB/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >>"$STUB_LOG"
count() { local n=0; [ ! -f "$STUB_DIR/$1" ] || n=$(cat "$STUB_DIR/$1"); n=$((n + 1)); echo "$n" >"$STUB_DIR/$1"; echo "$n"; }
case "$1" in
  fetch)
    n=$(count fetch)
    if [ "$n" -gt 1 ] && [ -n "${STUB_FETCH2_FAIL:-}" ]; then echo "fatal: unable to access" >&2; exit 1; fi
    exit 0 ;;
  merge-base)
    # The reviewed-sha ancestry check (any first ref but origin/develop): STUB_REVIEWED_ANCESTOR, default 0.
    [ "$3" = "origin/develop" ] || exit "${STUB_REVIEWED_ANCESTOR:-0}"
    case "$4" in syncsha*) [ "${4#syncsha}" -ge "${STUB_SYNC_OK_FROM:-1}" ] && exit 0; exit 1 ;; esac
    n=$(count merge-base)
    if [ "$n" -gt 1 ]; then exit "${STUB_ANCESTOR2:-$STUB_ANCESTOR}"; fi
    exit "$STUB_ANCESTOR" ;;
  show)
    [ -z "${STUB_SHOW_FAIL:-}" ] || { echo "fatal: path does not exist" >&2; exit 128; }
    case "$2" in
      origin/develop:*)
        n=$(count show-develop)
        if [ "$n" -gt 1 ]; then v="${STUB_DEV_VER2-$STUB_DEV_VER}"; else v="$STUB_DEV_VER"; fi ;;
      syncsha*) v="${STUB_SYNC_VER:-99.0.0}" ;;
      *:.claude-plugin/marketplace.json) v="${STUB_HEAD_MKT_VER-$STUB_HEAD_VER}" ;;
      *) v="$STUB_HEAD_VER" ;;
    esac
    printf '{\n  "version": "%s"\n}\n' "$v" ;;
  # STUB_COMMITS: space-separated "sha:file,file" for the non-merge commits after the reviewed sha.
  rev-list) for c in $STUB_COMMITS; do echo "${c%%:*}"; done ;;
  diff-tree)
    [ -z "${STUB_DIFFTREE_FAIL:-}" ] || { echo "fatal: bad object" >&2; exit 128; }
    for c in $STUB_COMMITS; do [ "${c%%:*}" = "${@: -1}" ] && { f=${c#*:}; printf '%s\n' ${f//,/ }; }; done ;;
  *) exit 2 ;;
esac
EOF
cat >"$STUB/uptime" <<'EOF'
#!/usr/bin/env bash
echo "10:00  up 1 day, 2 users, load averages: $STUB_LOAD 2.00 2.00"
EOF
# sync: logs "sync <branch> <head>", fails when STUB_SYNC_FAIL is set, else prints syncsha<n> for its
# n-th call (MERGE_PR_SYNC points the script at it).
cat >"$STUB/sync" <<'EOF'
#!/usr/bin/env bash
echo "sync $*" >>"$STUB_LOG"
[ -z "${STUB_SYNC_FAIL:-}" ] || { echo "sync-pr-head: conflicts outside the manifests" >&2; exit 1; }
n=0; [ ! -f "$STUB_DIR/sync-n" ] || n=$(cat "$STUB_DIR/sync-n"); n=$((n + 1)); echo "$n" >"$STUB_DIR/sync-n"
echo "syncsha$n"
EOF
chmod +x "$STUB/gh" "$STUB/git" "$STUB/uptime" "$STUB/sync"

# run <ancestor-rc> <remote-head> <load>; sets out, rc. Extra stub env (STUB_BASE, STUB_BASE2,
# STUB_EMPTY, STUB_ANCESTOR2, STUB_FETCH2_FAIL, STUB_HEAD_VER, STUB_HEAD_MKT_VER, STUB_DEV_VER,
# STUB_DEV_VER2, STUB_SHOW_FAIL) comes from the caller's environment.
run() {
  : >"$LOG"
  rm -f "$STUB/fetch" "$STUB/merge-base" "$STUB/show-develop" "$STUB/api" "$STUB/sync-n"
  out=$(PATH="$STUB:$PATH" STUB_LOG="$LOG" STUB_DIR="$STUB" STUB_HEAD=headsha111 \
    STUB_COMMITS="${STUB_COMMITS-}" STUB_COMMENTS_JSON="${STUB_COMMENTS_JSON-$(verdict 'MERGE @ abc1234')}" \
    STUB_ANCESTOR="$1" STUB_REMOTE_HEAD="$2" STUB_LOAD="$3" \
    STUB_HEAD_VER="${STUB_HEAD_VER-1.1.2}" STUB_DEV_VER="${STUB_DEV_VER-1.1.1}" \
    MERGE_PR_SYNC="$STUB/sync" MERGE_PR_LOAD_WAIT_SECS=0 MERGE_PR_LOAD_MAX=4 bash "$SCRIPT" 451 2>&1)
  rc=$?
}
merged() { /usr/bin/grep -q '^gh pr merge' "$LOG"; }
# merged_at <sha>: the merge call was pinned to <sha>.
merged_at() { /usr/bin/grep -q "^gh pr merge 451 --merge --match-head-commit $1\$" "$LOG"; }
syncs() { /usr/bin/grep -c '^sync ' "$LOG"; }
# synced_and_merged <label> [rounds]: exit 0, the sync ran [rounds] times (default 1) and the merge is
# pinned to the last synced head.
synced_and_merged() {
  local n=${2:-1}
  if [ "$rc" -eq 0 ] && [ "$(syncs)" -eq "$n" ] && merged_at "syncsha$n"; then ok "$1: synced ($n round(s)) and merged at syncsha$n"
  else bad "$1: rc=$rc syncs=$(syncs) out=$out log=$(cat "$LOG")"; fi
}
# merged_unsynced <label>: exit 0, no sync, merge pinned to the PR head.
merged_unsynced() {
  if [ "$rc" -eq 0 ] && [ "$(syncs)" -eq 0 ] && merged_at headsha111; then ok "$1: merged at the PR head with no sync"
  else bad "$1: rc=$rc syncs=$(syncs) out=$out log=$(cat "$LOG")"; fi
}
# verdict <text>: one PR comment whose body carries the line "## Fresh-context review: <text>".
verdict() { jq -nc --arg v "$1" '[{created_at: "2026-10-25T00:00:00Z", body: ("Some text.\n## Fresh-context review: " + $v + "\nmore")}]'; }
# comments <json-array>...: concatenate comment arrays, in order.
comments() { jq -sc 'add' <<<"$*"; }

# refuses <label> <message-pattern>: the last run() exited non-zero, never reached gh pr merge,
# and said why.
refuses() {
  if [ "$rc" -ne 0 ]; then ok "$1 exits non-zero (rc=$rc)"; else bad "$1 exited 0"; fi
  if merged; then bad "$1 still reached gh pr merge"; else ok "$1 never calls gh pr merge"; fi
  if /usr/bin/grep -q -- "$2" <<<"$out"; then ok "$1 message matches '$2'"; else bad "$1: no '$2' in: $out"; fi
}
# second_call_line <pattern>: line number in the stub log of the second matching call (empty
# when there is none), i.e. the call made after the load wait.
second_call_line() { awk -v p="$1" '$0 ~ p { n++; if (n == 2) { print NR; exit } }' "$LOG"; }

# 1. up to date: merges with the checked head pinned, prints the merge sha.
run 0 headsha111 1.50
if [ "$rc" -eq 0 ]; then ok "up-to-date PR exits 0"; else bad "up-to-date PR rc=$rc: $out"; fi
if /usr/bin/grep -q '^gh pr merge 451 --merge --match-head-commit headsha111$' "$LOG"; then
  ok "merge is pinned to the checked head sha"
else bad "merge call not pinned: $(cat "$LOG")"; fi
if [ "$(printf '%s\n' "$out" | tail -n 1)" = "mergesha000" ]; then
  ok "last line is the merge commit sha"
else bad "last line is not the merge sha: <$out>"; fi
if /usr/bin/grep -q '^git merge-base --is-ancestor origin/develop headsha111$' "$LOG"; then
  ok "ancestry checked against origin/develop"
else bad "no ancestry check: $(cat "$LOG")"; fi

if [ "$(syncs)" -eq 0 ]; then ok "an up-to-date head with a version above develop's is not synced"; else bad "up-to-date head was synced: $(cat "$LOG")"; fi

# 2. behind develop: the sync merges develop and bumps, gets the branch name and the head, and the
# merge is pinned to the synced head (it used to refuse and ask for a rebase).
run 1 syncsha1 1.50
synced_and_merged "behind PR"
if /usr/bin/grep -q '^sync feat/x headsha111$' "$LOG"; then ok "sync gets the head branch and the PR head"; else bad "sync args: $(cat "$LOG")"; fi
if [ "$(printf '%s\n' "$out" | tail -n 1)" = "mergesha000" ]; then ok "behind PR still prints the merge sha last"; else bad "behind PR last line: <$out>"; fi
# the sync runs after the load wait, so it sits right before the merge: never under high load.
run 1 syncsha1 7.25
refuses "behind PR under high load" "7.25"
if [ "$(syncs)" -eq 0 ]; then ok "no sync before the load wait"; else bad "synced before the load wait: $(cat "$LOG")"; fi

# 3. head mismatch: a push landed after the check; GitHub refuses, script fails.
run 0 othersha999 1.50
if [ "$rc" -ne 0 ]; then ok "head mismatch exits non-zero (rc=$rc)"; else bad "head mismatch exited 0"; fi
if merged; then ok "head mismatch reached gh pr merge with the checked sha"; else bad "head mismatch never tried the merge"; fi
if /usr/bin/grep -q 'mergesha000' <<<"$out"; then bad "head mismatch printed a merge sha"; else ok "head mismatch prints no merge sha"; fi

# 4. load stays high: fails with the figure, no merge.
run 0 headsha111 7.25
refuses "high load" "7.25"

# 4b. PR targets another branch: the develop ancestry check proves nothing, so refuse.
STUB_BASE=main run 0 headsha111 1.50
refuses "non-develop base" "not develop"

# 4c. base retargeted while waiting for load: the re-read before the merge refuses.
STUB_BASE2=main run 0 headsha111 1.50
refuses "retargeted base" "base changed"

# 4d. gh prints nothing: refuse before any merge.
STUB_EMPTY=1 run 0 headsha111 1.50
refuses "empty gh output" "could not read the head sha"

# 4e. develop moved during the first sync's push (the pre-push gauntlet takes minutes): a second round
# syncs the first synced head, and the merge is pinned to the second.
STUB_SYNC_OK_FROM=2 run 1 syncsha2 1.50
synced_and_merged "develop moved during the sync" 2
if /usr/bin/grep -q '^sync feat/x syncsha1$' "$LOG"; then ok "the second round syncs the first round's head"; else bad "second round args: $(cat "$LOG")"; fi
# every round starts from a fresh develop: a fetch sits between the two syncs.
if awk '/^sync /{s++} /^git fetch/{if (s == 1) f = 1} END {exit !f}' "$LOG"; then ok "git fetch runs between sync rounds"; else bad "no fetch between rounds: $(cat "$LOG")"; fi
# develop never holds still: refuse after MERGE_PR_SYNC_TRIES rounds, naming the count.
STUB_SYNC_OK_FROM=99 MERGE_PR_SYNC_TRIES=3 run 1 syncsha3 1.50
refuses "develop moving through every round" "after 3 sync rounds"
if [ "$(syncs)" -eq 3 ]; then ok "exactly MERGE_PR_SYNC_TRIES rounds"; else bad "rounds: $(syncs)"; fi

# 4e2. the fetch after the wait fails: say so and do not merge.
STUB_FETCH2_FAIL=1 run 0 headsha111 1.50
refuses "failed fetch after the wait" "git fetch failed after the load wait"

# 4e3. the sync fails (a conflict outside the manifests, a red gauntlet on its push): refuse with its words.
STUB_SYNC_FAIL=1 run 1 syncsha1 1.50
refuses "failed sync" "syncing PR 451 failed"
if /usr/bin/grep -q 'conflicts outside the manifests' <<<"$out"; then ok "the sync's own reason is shown"; else bad "sync reason missing: $out"; fi

# 4e4. a head branch from a fork cannot be pushed to: refuse instead of syncing.
STUB_CROSS=true run 1 syncsha1 1.50
refuses "fork PR that needs a sync" "not a branch of this repo"
if [ "$(syncs)" -eq 0 ]; then ok "a fork head is never synced"; else bad "fork head synced: $(cat "$LOG")"; fi

# 4f. same manifest version as origin/develop (a branch that never bumped, or bumped and lost the
# race): synced, not refused.
STUB_HEAD_VER=1.1.5 STUB_DEV_VER=1.1.5 run 0 syncsha1 1.50
synced_and_merged "same version"

# 4f2. develop's version moved to the head's during the load wait: the check after the wait syncs.
STUB_HEAD_VER=1.1.2 STUB_DEV_VER=1.1.2 run 0 syncsha1 1.50
synced_and_merged "version taken during the wait"

# 4f3. a head below develop's version (a stale bump, or a conflict resolved to a lower number): synced.
STUB_HEAD_VER=1.1.4 STUB_DEV_VER=1.1.5 run 0 syncsha1 1.50
synced_and_merged "version below develop's"

# 4f4. versions compare per number, not as text: 1.1.99 is below 1.1.100 (synced), 1.1.100 above 1.1.99.
STUB_HEAD_VER=1.1.99 STUB_DEV_VER=1.1.100 run 0 syncsha1 1.50
synced_and_merged "1.1.99 against 1.1.100"
STUB_HEAD_VER=1.1.100 STUB_DEV_VER=1.1.99 run 0 headsha111 1.50
merged_unsynced "1.1.100 against 1.1.99"

# 4f5. the opt-out spares only an equal version: a lower one is still synced.
MERGE_PR_ALLOW_SAME_VERSION=1 STUB_HEAD_VER=1.1.4 STUB_DEV_VER=1.1.5 run 0 syncsha1 1.50
synced_and_merged "opt-out with a version below develop's"

# 4f6. a version that is not plain X.Y.Z is handed to the sync (the stub syncs it; the real
# sync-pr-head.sh refuses one, which 4e3 covers); a synced head that still ships one is refused once the
# rounds run out.
STUB_HEAD_VER=1.1.196-rc1 STUB_HEAD_MKT_VER=1.1.196-rc1 run 0 syncsha1 1.50
synced_and_merged "non-numeric version"
STUB_HEAD_VER=1.1.196-rc1 STUB_HEAD_MKT_VER=1.1.196-rc1 STUB_SYNC_VER=1.1.196-rc1 MERGE_PR_SYNC_TRIES=1 run 0 syncsha1 1.50
refuses "non-numeric version after the sync" "after 1 sync rounds"

# 4f7. a leading zero reads as the same number to awk but not to the equal-version guard, so it goes to
# the sync (the stub syncs it; the real sync-pr-head.sh refuses a non-X.Y.Z version, which 4e3 covers).
STUB_HEAD_VER=01.1.5 STUB_HEAD_MKT_VER=01.1.5 STUB_DEV_VER=1.1.5 run 0 syncsha1 1.50
synced_and_merged "leading-zero version"

# 4g. opt-out for a PR that needs no bump: an equal version merges as is.
MERGE_PR_ALLOW_SAME_VERSION=1 STUB_HEAD_VER=1.1.5 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
merged_unsynced "same version with the opt-out"

# 4h. unreadable manifest version at the head: it goes to the sync (the stub syncs it; the real
# sync-pr-head.sh refuses a head whose plugin.json version it cannot read, which 4e3 covers).
STUB_HEAD_VER='' run 0 syncsha1 1.50
synced_and_merged "unreadable version"

# 4j. the two manifests at the head disagree: synced (checking plugin.json alone would miss it).
STUB_HEAD_MKT_VER=1.1.9 run 0 syncsha1 1.50
synced_and_merged "manifest mismatch"

# 4k. no manifest readable anywhere (git show fails): the sync fails too, and the script refuses.
STUB_SHOW_FAIL=1 STUB_SYNC_FAIL=1 run 0 syncsha1 1.50
refuses "unreadable manifest file" "syncing PR 451 failed"

# 6. review verdict (2026-10-25). No verdict comment at all: refuse, before the load wait.
STUB_COMMENTS_JSON='[{"created_at":"2026-10-25T00:00:00Z","body":"A fresh-context review of this PR is in progress."}]' run 0 headsha111 7.25
refuses "no review verdict" "no \"Fresh-context review: MERGE @ <sha>\""
if /usr/bin/grep -q 'load' <<<"$out"; then bad "no verdict refused only after the load wait: $out"; else ok "no verdict is refused before the load wait"; fi

# 6b. the latest verdict is FIX FIRST, even with an earlier MERGE: refuse and name it.
STUB_COMMENTS_JSON=$(comments "$(verdict 'MERGE @ abc1234')" "$(verdict 'FIX FIRST')") run 0 headsha111 1.50
refuses "latest verdict FIX FIRST" "is FIX FIRST, not MERGE"

# 6c. FIX FIRST then a later MERGE on the head (a re-review after the fix): merges.
STUB_COMMENTS_JSON=$(comments "$(verdict 'FIX FIRST')" "$(verdict 'MERGE @ 0f1e2d3c')") run 0 headsha111 1.50
if [ "$rc" -eq 0 ] && merged; then ok "FIX FIRST then MERGE merges"; else bad "FIX FIRST then MERGE rc=$rc: $out"; fi

# 6d. a substantive commit after the reviewed sha: refuse, whatever its timestamps say (the reviewer's
# finding: a fix committed before the review but pushed after it used to pass the time comparison).
STUB_COMMITS="c2:hooks/gates/irrecoverable.py" run 0 headsha111 1.50
refuses "a change after the reviewed sha" "commit c2 touches more than the manifests"

# 6e. a manifest-only commit after the reviewed sha (a version bump after syncing develop) keeps the review.
STUB_COMMITS="c2:.claude-plugin/plugin.json,.claude-plugin/marketplace.json" run 0 headsha111 1.50
if [ "$rc" -eq 0 ] && merged; then ok "a version bump after the review keeps it"; else bad "manifest-only commit lost the review rc=$rc: $out"; fi
# ...but one that also touches another file does not.
STUB_COMMITS="c2:.claude-plugin/plugin.json,scripts/merge-pr.sh" run 0 headsha111 1.50
refuses "a bump plus another file after the review" "commit c2 touches more than the manifests"

# 6f. a lower-case, bold verdict with a backticked sha and trailing words reads as MERGE; CLOSE refuses.
STUB_COMMENTS_JSON='[{"created_at":"2026-10-25T00:00:00Z","body":"## **Fresh-context review: merge** @ `abc1234` after re-sync"}]' run 0 headsha111 1.50
if [ "$rc" -eq 0 ]; then ok "case, bold and a backticked sha do not hide a MERGE verdict"; else bad "styled MERGE verdict rc=$rc: $out"; fi
STUB_COMMENTS_JSON=$(verdict 'CLOSE') run 0 headsha111 1.50
refuses "CLOSE verdict" "is CLOSE"

# 6g. a FIX FIRST posted during the load wait: the re-check after the wait refuses.
STUB_COMMENTS_JSON2=$(comments "$(verdict 'MERGE @ abc1234')" "$(verdict 'FIX FIRST')") run 0 headsha111 1.50
refuses "FIX FIRST posted during the wait" "is FIX FIRST"

# 6h. the comments cannot be read: refuse, do not treat it as "no verdict needed".
STUB_API_FAIL=1 run 0 headsha111 1.50
refuses "unreadable comments" "could not read the comments"

# 6i. a MERGE that names no reviewed commit: refuse and show the expected form.
STUB_COMMENTS_JSON=$(verdict 'MERGE') run 0 headsha111 1.50
refuses "MERGE without a sha" "names no reviewed commit"

# 6j. the reviewed sha is not in the head's history (rewritten history, or a sha from another PR).
STUB_REVIEWED_ANCESTOR=1 run 0 headsha111 1.50
refuses "reviewed sha not an ancestor" "not in the head's history"

# 6k. a verdict line inside a code fence does not count: a fenced MERGE then a real FIX FIRST is FIX
# FIRST, and a comment with only a fenced MERGE has no verdict.
STUB_COMMENTS_JSON='[{"created_at":"2026-10-25T00:00:00Z","body":"```\nFresh-context review: MERGE @ abc1234\n```\n## Fresh-context review: FIX FIRST"}]' run 0 headsha111 1.50
refuses "fenced MERGE before a real FIX FIRST" "is FIX FIRST"
STUB_COMMENTS_JSON='[{"created_at":"2026-10-25T00:00:00Z","body":"~~~\nFresh-context review: MERGE @ abc1234\n~~~"}]' run 0 headsha111 1.50
refuses "only a fenced MERGE" "no \"Fresh-context review"

# 6l. git diff-tree fails on a commit after the reviewed sha: refuse (it used to read as not substantive).
STUB_COMMITS="c2:hooks/gates/irrecoverable.py" STUB_DIFFTREE_FAIL=1 run 0 headsha111 1.50
refuses "diff-tree failure" "diff-tree c2 failed"

# 4l. a MERGE_PR_SYNC_TRIES that is not a whole number would disarm the round cap: refuse up front, before
# the load wait (load 7.25 would otherwise wait) and before any sync.
MERGE_PR_SYNC_TRIES=abc run 1 syncsha1 7.25
refuses "non-numeric MERGE_PR_SYNC_TRIES" "MERGE_PR_SYNC_TRIES must be a whole number"
if [ "$(syncs)" -eq 0 ] && ! /usr/bin/grep -q 'load' <<<"$out"; then ok "refused before the load wait and any sync"; else bad "late refusal: $out"; fi
MERGE_PR_SYNC_TRIES=0 run 1 syncsha1 1.50
refuses "MERGE_PR_SYNC_TRIES=0 on a head that needs a sync" "after 0 sync rounds"

# 5. no PR argument: usage error.
out=$(PATH="$STUB:$PATH" STUB_LOG="$LOG" bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok "missing PR argument exits non-zero"; else bad "missing PR argument exited 0"; fi

safe_trash "$STUB"
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
