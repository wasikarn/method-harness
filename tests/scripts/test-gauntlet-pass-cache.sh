#!/usr/bin/env bash
# test-gauntlet-pass-cache.sh — GH #735: scripts/run-gauntlet.sh records a pass under
# $GAUNTLET_PASS_DIR/<HEAD^{tree}> only after a full (unsharded) run where every layer passed, on a
# checkout identical to HEAD at the start and at the end. merge-pr.sh and sync-pr-head.sh skip their
# gauntlet on a hit (tested in their own files). This drives scripts/_lib/gauntlet-pass.sh in a fixture
# repo and checks run-gauntlet.sh's wiring by text: running the real gauntlet here would recurse.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet pass cache: recorded only for a full, clean, passing run (GH #735) ==="

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
R=$(fresh_repo) || exit 1
[ -n "$R" ] || exit 1
export GAUNTLET_PASS_DIR="$R.pass" GAUNTLET_PASS_CACHE=1
track_trash "$GAUNTLET_PASS_DIR"
# shellcheck source=../../scripts/_lib/gauntlet-pass.sh
. "$ROOT/scripts/_lib/gauntlet-pass.sh"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
echo a >"$R/a.txt"; echo 'ignored.log' >"$R/.gitignore"
g add a.txt .gitignore && g commit -q -m base
tree() { g rev-parse 'HEAD^{tree}'; }
entries() { if [ -d "$GAUNTLET_PASS_DIR" ]; then find "$GAUNTLET_PASS_DIR" -type f | wc -l | tr -d ' '; else echo 0; fi; }
reset_cache() { [ ! -d "$GAUNTLET_PASS_DIR" ] || tmp_delete "$GAUNTLET_PASS_DIR"; }
# record <fail> <shard> [mid-run command]: one run's start, an optional change during it, its record.
record() {
  local start
  start=$(cd "$R" && gauntlet_pass_start)
  [ -z "${3:-}" ] || (cd "$R" && eval "$3")
  (cd "$R" && gauntlet_pass_record "$1" "$2" "$start") >/dev/null
}

reset_cache; record 0 ""
if [ -f "$GAUNTLET_PASS_DIR/$(tree)" ] && [ "$(entries)" = 1 ]; then ok "a full, clean, passing run records its tree"; else bad "no entry for a clean pass ($(entries))"; fi

reset_cache; record 1 ""
[ "$(entries)" = 0 ] && ok "a failing run records nothing" || bad "a failing run wrote an entry"

reset_cache; record 0 "1/2"
[ "$(entries)" = 0 ] && ok "a sharded run records nothing" || bad "a sharded run wrote an entry"

reset_cache; echo dirty >>"$R/a.txt"; record 0 ""; g checkout -q -- a.txt
[ "$(entries)" = 0 ] && ok "a run that starts with a modified file records nothing" || bad "dirty start wrote an entry"

reset_cache; echo new >"$R/untracked.txt"; record 0 ""; tmp_delete "$R/untracked.txt"
[ "$(entries)" = 0 ] && ok "a run that starts with an untracked file records nothing" || bad "untracked start wrote an entry"

reset_cache; record 0 "" 'echo new >untracked.txt'; tmp_delete "$R/untracked.txt"
[ "$(entries)" = 0 ] && ok "a run whose checkout changes before the end records nothing" || bad "dirty end wrote an entry"

reset_cache; record 0 "" 'echo b >b.txt && git -c user.name=t -c user.email=t@example.com add b.txt && git -c user.name=t -c user.email=t@example.com commit -q -m mid'
[ "$(entries)" = 0 ] && ok "a run whose HEAD tree moves (a commit during the run) records nothing" || bad "moved tree wrote an entry"

reset_cache; echo x >"$R/ignored.log"; record 0 ""
[ -f "$GAUNTLET_PASS_DIR/$(tree)" ] && ok "an ignored file does not count as dirty" || bad "an ignored file blocked the entry"

reset_cache; GAUNTLET_PASS_CACHE=0 record 0 ""
[ "$(entries)" = 0 ] && ok "GAUNTLET_PASS_CACHE=0 writes nothing" || bad "the opt-out still wrote an entry"

# Wiring: the record call sits in the all-passed branch with the run's own fail/shard/start values, the
# start tree is read before the first layer launches, and a test-layer child gauntlet never records.
NL=$'\n'
body=$(cat "$GAUNTLET")
start_line=$(/usr/bin/grep -n '^start_tree=$(gauntlet_pass_start)$' "$GAUNTLET" | head -1 | cut -d: -f1)
launch_line=$(/usr/bin/grep -n '^p1="" p2=""$' "$GAUNTLET" | head -1 | cut -d: -f1)
if [ -n "$start_line" ] && [ -n "$launch_line" ] && [ "$start_line" -lt "$launch_line" ]; then
  ok "run-gauntlet.sh reads the start tree before any layer launches"
else bad "start tree line ($start_line) not before the layer launch ($launch_line)"; fi
case "$body" in
  *"echo \"gauntlet: all layers passed\"${NL}  gauntlet_pass_record \"\$fail\" \"\$shard\" \"\$start_tree\""*) ok "run-gauntlet.sh records only in its all-layers-passed branch" ;;
  *) bad "run-gauntlet.sh does not call gauntlet_pass_record right after 'all layers passed'" ;;
esac
case "$body" in
  *"export GAUNTLET_PASS_CACHE=0"*) ok "the test layer turns the cache off for the gauntlets its tests run" ;;
  *) bad "run_hook_tests does not export GAUNTLET_PASS_CACHE=0" ;;
esac

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
