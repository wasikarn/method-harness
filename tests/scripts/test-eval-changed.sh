#!/usr/bin/env bash
# test-eval-changed.sh — scripts/eval-changed.sh without model calls: a stub `claude` on PATH
# records each call's argv and whether defaultEnabled was true at that moment. Covers case
# selection by any `tags:` entry (not the eval dir's name prefix, the first tag, or a substring),
# the defaultEnabled wrap on every tag, staged-only changes, and the exit status when a tag's
# eval fails or the <ref> does not resolve.
set -uo pipefail
# The fixture repo below runs `git init`; a hook-exported GIT_DIR would retarget it at the real repo.
# BASH_ENV/ENV: a startup file there could put the real, paid claude ahead of the stub (GH #803).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE BASH_ENV ENV
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
TMP="$(mktemp -d)" || exit 1
[ -n "$TMP" ] || { echo "test-eval-changed: mktemp gave an empty path" >&2; exit 1; }
trap 'tmp_delete "$TMP"' EXIT

echo "=== eval-changed self-test ==="

R="$TMP/repo"
mkdir -p "$R/scripts/_lib" "$R/.claude-plugin" "$R/agents" "$R/skills/x/performance-optimizer" "$R/bin"
cp "$ROOT/scripts/eval-changed.sh" "$R/scripts/"
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$ROOT/scripts/_lib/eval_judge_models.py" "$R/scripts/_lib/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
case_md() { mkdir -p "$R/evals/$1"; printf -- '---\nname: %s\ntags: [%s]\nallowed_tools: [%s]\n---\nprompt\n' "$1" "$2" "$3" >"$R/evals/$1/prompt.md"; }
# Mirrors evals/perf-*: the dir prefix is not the tag, the bug this test was written for.
case_md perf-a "performance-optimizer, planted" "Bash, Read, Write"
case_md perf-b "performance-optimizer, clean" "Edit, Skill"
case_md backend-architect-a "backend-architect, planted" "Agent, Grep"
case_md zz-agent-a "zz-agent, clean" "Read"
case_md other-b "other, zz-agent" "Bash"       # zz-agent is not the first tag: still selected
case_md zz-agent-decoy "zz-other" "Write"      # dir prefix matches, tag does not: not selected
case_md zz-agent-x-a "zz-agent-x" "Glob"       # tag contains zz-agent as a substring: not selected
case_md zz-staged-a "zz-staged" "Read"
mkdir -p "$R/evals/zz-bare-a"                   # no allowed_tools, or an empty one: no --allow-tools at all
printf -- '---\nname: zz-bare-a\ntags: [zz-bare]\n---\nprompt\n' >"$R/evals/zz-bare-a/prompt.md"
case_md zz-bare-b "zz-bare" ""
CHANGED="agents/zz-agent.md agents/backend-architect.md agents/zz-bare.md agents/zz-staged.md skills/x/performance-optimizer/SKILL.md"
for f in $CHANGED; do echo a >"$R/$f"; done
git -C "$R" init -q && git -C "$R" add agents evals scripts skills .claude-plugin && git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init || { echo "test-eval-changed: fixture commit failed" >&2; exit 1; }
for f in $CHANGED; do echo b >>"$R/$f"; done
# Staged only: stage the change, then put the work-tree copy back, so only git diff --cached sees it.
git -C "$R" add agents/zz-staged.md && echo a >"$R/agents/zz-staged.md"

cat >"$R/bin/claude" <<'SH'
#!/usr/bin/env bash
en=$(/usr/bin/grep -o '"defaultEnabled": *[a-z]*' "$EC_MANIFEST" | sed 's/.*: *//')
echo "enabled=$en $*" >>"$EC_LOG"
case " $* " in *" --tag ${EC_FAIL_TAG:-} "*) exit 3 ;; esac
SH
chmod +x "$R/bin/claude"
export EC_LOG="$TMP/calls.log" EC_MANIFEST="$R/.claude-plugin/plugin.json"
before=$(shasum "$EC_MANIFEST" | cut -d' ' -f1)

# tag -> the exact argv expected after `claude` (derived from the fixture cases above)
expect() {
  case "$1" in
    backend-architect) echo "plugin eval . --scaffold --tag backend-architect --runs 1 --no-publish --allow-tools Agent,Grep" ;;
    performance-optimizer) echo "plugin eval . --scaffold --tag performance-optimizer --runs 1 --no-publish --allow-tools Bash,Edit,Read,Skill,Write" ;;
    zz-agent) echo "plugin eval . --scaffold --tag zz-agent --runs 1 --no-publish --allow-tools Bash,Read" ;;
    zz-bare) echo "plugin eval . --scaffold --tag zz-bare --runs 1 --no-publish" ;;
    zz-staged) echo "plugin eval . --scaffold --tag zz-staged --runs 1 --no-publish --allow-tools Read" ;;
  esac
}
TAGS="backend-architect performance-optimizer zz-agent zz-bare zz-staged"

PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >"$TMP/run.out" 2>"$TMP/run.err" \
  && ok "--run exits 0" || bad "--run exited non-zero: $(cat "$TMP/run.err")"
for t in $TAGS; do
  l=$(/usr/bin/grep -- "--tag $t " "$EC_LOG")
  [ "$l" = "enabled=true $(expect "$t")" ] && ok "$t: exact argv, run with defaultEnabled true" \
    || bad "$t: run line wrong: '$l' (want 'enabled=true $(expect "$t")')"
done
[ "$(wc -l <"$EC_LOG" | tr -d ' ')" = 5 ] && ok "one call per changed tag, no extra tag" || bad "call count wrong: $(cat "$EC_LOG")"
[ "$(shasum "$EC_MANIFEST" | cut -d' ' -f1)" = "$before" ] && ok "manifest restored after --run" || bad "manifest left changed"

# A failing eval for one tag must not be hidden by a later tag's success, nor stop the later tags.
: >"$EC_LOG"
EC_FAIL_TAG=zz-bare PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "--run exits non-zero when an earlier tag's eval fails (exit $rc)" || bad "--run exited 0 although zz-bare's eval failed"
/usr/bin/grep -q -- "--tag zz-staged " "$EC_LOG" && ok "tags after a failed one still run" || bad "zz-staged did not run after zz-bare failed"

# Print mode: every line is the README run-block form, runnable as pasted.
PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" >"$TMP/print.out" 2>&1 \
  && ok "print mode exits 0" || bad "print mode exited non-zero: $(cat "$TMP/print.out")"
for t in $TAGS; do
  p=$(/usr/bin/grep -- "--tag $t " "$TMP/print.out")
  [ "$p" = "bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude $(expect "$t")'" ] \
    && ok "print mode: $t printed in full, in the bash -c helper form" || bad "print mode $t line wrong: '$p'"
done

# A <ref> git cannot resolve is an error, not "nothing to eval".
PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" no-such-ref >"$TMP/ref.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "an unresolvable <ref> exits non-zero (exit $rc)" || bad "an unresolvable <ref> exited 0: $(cat "$TMP/ref.out")"

echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
