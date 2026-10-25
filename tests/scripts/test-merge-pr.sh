#!/usr/bin/env bash
# test-merge-pr.sh — GH #450: scripts/merge-pr.sh merges only a PR whose head
# contains the origin/develop tip, pinned with --match-head-commit, and whose two manifests
# agree on a version above origin/develop's (both checked before and after the load wait;
# #492/#493, #496/#497 cut the same number). Stubs gh,
# git and uptime on PATH; never touches GitHub. Each failing case also checks
# that `gh pr merge` was never reached (or, for a head mismatch, that it was
# reached with the checked sha and its refusal propagated). It also needs a "Fresh-context review:
# MERGE" comment posted after the PR's last substantive commit (2026-10-25: #569-#576 and #611 merged
# with FIX FIRST reviews open); the gh stub runs the script's own jq on fake comments.
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
#   merge-base --is-ancestor: exits STUB_ANCESTOR on call 1, STUB_ANCESTOR2 (default
#     STUB_ANCESTOR) after.
#   show <ref>:<manifest>: prints a manifest whose version is STUB_HEAD_VER (PR head,
#     plugin.json), STUB_HEAD_MKT_VER (PR head, marketplace.json, default STUB_HEAD_VER) or
#     STUB_DEV_VER (origin/develop; STUB_DEV_VER2 from its second read on, default STUB_DEV_VER).
#     STUB_SHOW_FAIL makes every show fail like a missing path.
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
    n=$(count merge-base)
    if [ "$n" -gt 1 ]; then exit "${STUB_ANCESTOR2:-$STUB_ANCESTOR}"; fi
    exit "$STUB_ANCESTOR" ;;
  show)
    [ -z "${STUB_SHOW_FAIL:-}" ] || { echo "fatal: path does not exist" >&2; exit 128; }
    case "$2" in
      origin/develop:*)
        n=$(count show-develop)
        if [ "$n" -gt 1 ]; then v="${STUB_DEV_VER2-$STUB_DEV_VER}"; else v="$STUB_DEV_VER"; fi ;;
      *:.claude-plugin/marketplace.json) v="${STUB_HEAD_MKT_VER-$STUB_HEAD_VER}" ;;
      *) v="$STUB_HEAD_VER" ;;
    esac
    printf '{\n  "version": "%s"\n}\n' "$v" ;;
  # STUB_COMMITS: space-separated "sha:committer-epoch:file,file" for the PR's non-merge commits.
  rev-list) for c in $STUB_COMMITS; do echo "${c%%:*}"; done ;;
  diff-tree) for c in $STUB_COMMITS; do [ "${c%%:*}" = "${@: -1}" ] && { f=${c##*:}; printf '%s\n' ${f//,/ }; }; done ;;
  log) for c in $STUB_COMMITS; do [ "${c%%:*}" = "${@: -1}" ] && { r=${c#*:}; echo "${r%%:*}"; }; done ;;
  *) exit 2 ;;
esac
EOF
cat >"$STUB/uptime" <<'EOF'
#!/usr/bin/env bash
echo "10:00  up 1 day, 2 users, load averages: $STUB_LOAD 2.00 2.00"
EOF
chmod +x "$STUB/gh" "$STUB/git" "$STUB/uptime"

# run <ancestor-rc> <remote-head> <load>; sets out, rc. Extra stub env (STUB_BASE, STUB_BASE2,
# STUB_EMPTY, STUB_ANCESTOR2, STUB_FETCH2_FAIL, STUB_HEAD_VER, STUB_HEAD_MKT_VER, STUB_DEV_VER,
# STUB_DEV_VER2, STUB_SHOW_FAIL) comes from the caller's environment.
run() {
  : >"$LOG"
  rm -f "$STUB/fetch" "$STUB/merge-base" "$STUB/show-develop" "$STUB/api"
  out=$(PATH="$STUB:$PATH" STUB_LOG="$LOG" STUB_DIR="$STUB" STUB_HEAD=headsha111 \
    STUB_COMMITS="${STUB_COMMITS-c1:1000:hooks/gates/irrecoverable.py}" \
    STUB_COMMENTS_JSON="${STUB_COMMENTS_JSON-$(verdict 2000 MERGE)}" \
    STUB_ANCESTOR="$1" STUB_REMOTE_HEAD="$2" STUB_LOAD="$3" \
    STUB_HEAD_VER="${STUB_HEAD_VER-1.1.2}" STUB_DEV_VER="${STUB_DEV_VER-1.1.1}" \
    MERGE_PR_LOAD_WAIT_SECS=0 MERGE_PR_LOAD_MAX=4 bash "$SCRIPT" 451 2>&1)
  rc=$?
}
merged() { /usr/bin/grep -q '^gh pr merge' "$LOG"; }
# verdict <epoch> <word>...: one PR comment, created at <epoch>, whose body carries a review verdict line.
verdict() { jq -nc --argjson t "$1" --arg v "${*:2}" '[{created_at: ($t | todateiso8601), body: ("Some text.\n## Fresh-context review: " + $v + "\nmore")}]'; }
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

# 2. behind: fails before merging, tells the agent to rebase.
run 1 headsha111 1.50
refuses "behind PR" "ebase on origin/develop"

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

# 4e. develop moved during the load wait: the first ancestry check passed, the second fails.
STUB_ANCESTOR2=1 run 0 headsha111 1.50
refuses "develop moved after the first check" "does not contain origin/develop"
if [ "$(/usr/bin/grep -c '^git merge-base' "$LOG")" -eq 2 ]; then ok "ancestry re-checked after the wait"; else bad "ancestry not re-checked: $(cat "$LOG")"; fi
# the re-check must see a fresh develop: a fetch sits between the two merge-base calls.
second_fetch=$(second_call_line '^git fetch'); second_mb=$(second_call_line '^git merge-base')
if [ "$(/usr/bin/grep -c '^git fetch' "$LOG")" -eq 2 ] && [ -n "$second_mb" ] && [ "$second_fetch" -lt "$second_mb" ]; then
  ok "git fetch runs before the second ancestry check"
else bad "no fetch before the second ancestry check: $(cat "$LOG")"; fi

# 4e2. the fetch after the wait fails: say so and do not merge.
STUB_FETCH2_FAIL=1 run 0 headsha111 1.50
refuses "failed fetch after the wait" "git fetch failed after the load wait"

# 4f. same manifest version as origin/develop: refuse before merging (identical bumps rebase away).
STUB_HEAD_VER=1.1.5 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
refuses "same version" "1.1.5"

# 4f2. develop's version moved to the head's during the load wait: only the post-wait check sees it.
STUB_HEAD_VER=1.1.2 STUB_DEV_VER=1.1.1 STUB_DEV_VER2=1.1.2 run 0 headsha111 1.50
refuses "version taken during the wait" "1.1.2"

# 4f3. a head below develop's version (a conflict resolved to a lower number) is refused too.
STUB_HEAD_VER=1.1.4 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
refuses "version below develop's" "below"

# 4f4. versions compare per number, not as text: 1.1.99 is below 1.1.100.
STUB_HEAD_VER=1.1.99 STUB_DEV_VER=1.1.100 run 0 headsha111 1.50
refuses "1.1.99 against 1.1.100" "below"
STUB_HEAD_VER=1.1.100 STUB_DEV_VER=1.1.99 run 0 headsha111 1.50
if [ "$rc" -eq 0 ]; then ok "1.1.100 against 1.1.99 merges"; else bad "1.1.100 against 1.1.99 rc=$rc: $out"; fi

# 4f5. the opt-out skips only the equal-version refusal, never the below-develop one.
MERGE_PR_ALLOW_SAME_VERSION=1 STUB_HEAD_VER=1.1.4 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
refuses "opt-out with a version below develop's" "below"

# 4f6. a version that is not plain X.Y.Z cannot be ordered safely: refuse and say so.
STUB_HEAD_VER=1.1.196-rc1 STUB_HEAD_MKT_VER=1.1.196-rc1 run 0 headsha111 1.50
refuses "non-numeric version" "not X.Y.Z"

# 4f7. a leading zero reads as the same number to awk but not to the equal-version guard: refuse.
STUB_HEAD_VER=01.1.5 STUB_HEAD_MKT_VER=01.1.5 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
refuses "leading-zero version" "not X.Y.Z"

# 4g. opt-out for a PR that needs no bump.
MERGE_PR_ALLOW_SAME_VERSION=1 STUB_HEAD_VER=1.1.5 STUB_DEV_VER=1.1.5 run 0 headsha111 1.50
if [ "$rc" -eq 0 ]; then ok "same version with the opt-out merges"; else bad "opt-out rc=$rc: $out"; fi

# 4h. unreadable manifest version: refuse.
STUB_HEAD_VER='' run 0 headsha111 1.50
refuses "unreadable version" "could not read"

# 4i. a same-version head fails fast, before the load wait (load 7.25 would otherwise wait).
STUB_HEAD_VER=1.1.5 STUB_DEV_VER=1.1.5 run 0 headsha111 7.25
refuses "same version under high load" "1.1.5"
if /usr/bin/grep -q 'load' <<<"$out"; then bad "refused after the load wait: $out"; else ok "same version is refused before the load wait"; fi

# 4j. the two manifests at the head disagree: refuse (checking plugin.json alone would miss it).
STUB_HEAD_MKT_VER=1.1.9 run 0 headsha111 1.50
refuses "manifest mismatch" "marketplace"

# 4k. a manifest missing at the head (git show fails): the script says which one and refuses.
STUB_SHOW_FAIL=1 run 0 headsha111 1.50
refuses "unreadable manifest file" "cannot read"

# 6. review verdict (2026-10-25). No verdict comment at all: refuse, before the load wait.
STUB_COMMENTS_JSON='[{"created_at":"1970-01-01T01:00:00Z","body":"A fresh-context review of this PR is in progress."}]' run 0 headsha111 7.25
refuses "no review verdict" "no \"Fresh-context review: MERGE\""
if /usr/bin/grep -q 'load' <<<"$out"; then bad "no verdict refused only after the load wait: $out"; else ok "no verdict is refused before the load wait"; fi

# 6b. the latest verdict is FIX FIRST, even with an earlier MERGE: refuse and name it.
STUB_COMMENTS_JSON=$(comments "$(verdict 2000 MERGE)" "$(verdict 3000 FIX FIRST)") run 0 headsha111 1.50
refuses "latest verdict FIX FIRST" "is FIX FIRST, not MERGE"

# 6c. FIX FIRST then a later MERGE (a re-review after the fix): merges.
STUB_COMMENTS_JSON=$(comments "$(verdict 2000 FIX FIRST)" "$(verdict 3000 MERGE)") run 0 headsha111 1.50
if [ "$rc" -eq 0 ] && merged; then ok "FIX FIRST then MERGE merges"; else bad "FIX FIRST then MERGE rc=$rc: $out"; fi

# 6d. MERGE posted before the last substantive commit: stale, refuse.
STUB_COMMITS="c1:1000:hooks/gates/irrecoverable.py c2:2500:tests/hooks/test-gates.sh" run 0 headsha111 1.50
refuses "verdict older than the last change" "no \"Fresh-context review: MERGE\""

# 6e. a later manifest-only commit (a version bump after syncing develop) keeps the review.
STUB_COMMITS="c1:1000:hooks/gates/irrecoverable.py c2:2500:.claude-plugin/plugin.json,.claude-plugin/marketplace.json" run 0 headsha111 1.50
if [ "$rc" -eq 0 ] && merged; then ok "a version bump after the review keeps it"; else bad "manifest-only commit lost the review rc=$rc: $out"; fi

# 6f. a lower-case, bold verdict line with trailing words still reads as MERGE; CLOSE refuses.
STUB_COMMENTS_JSON='[{"created_at":"1970-01-01T00:33:20Z","body":"**fresh-context review: merge** after re-sync"}]' run 0 headsha111 1.50
if [ "$rc" -eq 0 ]; then ok "case and bold do not hide a MERGE verdict"; else bad "styled MERGE verdict rc=$rc: $out"; fi
STUB_COMMENTS_JSON=$(verdict 2000 CLOSE) run 0 headsha111 1.50
refuses "CLOSE verdict" "is CLOSE"

# 6g. a FIX FIRST posted during the load wait: the re-check after the wait refuses.
STUB_COMMENTS_JSON2=$(comments "$(verdict 2000 MERGE)" "$(verdict 3000 FIX FIRST)") run 0 headsha111 1.50
refuses "FIX FIRST posted during the wait" "is FIX FIRST"

# 6h. the comments cannot be read: refuse, do not treat it as "no verdict needed".
STUB_API_FAIL=1 run 0 headsha111 1.50
refuses "unreadable comments" "could not read the comments"

# 5. no PR argument: usage error.
out=$(PATH="$STUB:$PATH" STUB_LOG="$LOG" bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok "missing PR argument exits non-zero"; else bad "missing PR argument exited 0"; fi

safe_trash "$STUB"
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
