#!/usr/bin/env bash
# test-eval-changed.sh — scripts/eval-changed.sh without model calls: a stub `claude` on PATH
# records each call's argv and whether defaultEnabled was true at that moment. Covers case
# selection by any `tags:` entry (not the eval dir's name prefix or the first tag) and the
# defaultEnabled wrap for tags that load an mh agent or skill.
set -uo pipefail
# The fixture repo below runs `git init`; a hook-exported GIT_DIR would retarget it at the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
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
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$R/scripts/_lib/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
# The real perf-* cases: their dir prefix is not their tag, the bug this test was written for.
for p in "$ROOT"/evals/*/prompt.md; do
  d="$R/evals/$(basename "$(dirname "$p")")"; mkdir -p "$d"; cp "$p" "$d/"
done
case_md() { mkdir -p "$R/evals/$1"; printf -- '---\nname: %s\ntags: [%s]\nallowed_tools: [%s]\n---\nprompt\n' "$1" "$2" "$3" >"$R/evals/$1/prompt.md"; }
case_md zz-agent-a "zz-agent, clean" "Read"
case_md other-b "other, zz-agent" "Bash"       # zz-agent is not the first tag: still selected
case_md zz-agent-decoy "zz-other" "Write"      # dir prefix matches, tag does not: not selected
echo a >"$R/agents/zz-agent.md"; echo a >"$R/agents/backend-architect.md"; echo a >"$R/skills/x/performance-optimizer/SKILL.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init || { echo "test-eval-changed: fixture commit failed" >&2; exit 1; }
echo b >>"$R/agents/zz-agent.md"; echo b >>"$R/agents/backend-architect.md"; echo b >>"$R/skills/x/performance-optimizer/SKILL.md"

cat >"$R/bin/claude" <<'SH'
#!/usr/bin/env bash
en=$(/usr/bin/grep -o '"defaultEnabled": *[a-z]*' "$EC_MANIFEST" | sed 's/.*: *//')
echo "enabled=$en $*" >>"$EC_LOG"
SH
chmod +x "$R/bin/claude"
export EC_LOG="$TMP/calls.log" EC_MANIFEST="$R/.claude-plugin/plugin.json"
before=$(shasum "$EC_MANIFEST" | cut -d' ' -f1)

PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >"$TMP/run.out" 2>"$TMP/run.err" \
  && ok "--run exits 0" || bad "--run exited non-zero: $(cat "$TMP/run.err")"
line() { /usr/bin/grep -- "--tag $1 " "$EC_LOG"; }

l=$(line performance-optimizer)
[[ "$l" == *"--allow-tools Agent,Bash,Edit,Glob,Grep,Read,Skill,Write"* ]] \
  && ok "performance-optimizer: perf-* cases' allowed_tools reach --allow-tools" || bad "performance-optimizer allow-tools wrong: '$l'"
[[ "$l" == enabled=true* ]] && ok "performance-optimizer: runs with defaultEnabled true" || bad "performance-optimizer not wrapped: '$l'"

l=$(line backend-architect)
[[ "$l" == *"--allow-tools Agent,Bash,Glob,Grep,Read"* ]] && ok "backend-architect: allow-tools union" || bad "backend-architect allow-tools wrong: '$l'"
[[ "$l" == enabled=true* ]] && ok "backend-architect: runs with defaultEnabled true" || bad "backend-architect not wrapped: '$l'"

l=$(line zz-agent)
[[ "$l" == *"--allow-tools Bash,Read" || "$l" == *"--allow-tools Bash,Read "* ]] \
  && ok "zz-agent: any-tag match in, prefix-only decoy out" || bad "zz-agent allow-tools wrong: '$l'"
[[ "$l" == enabled=false* ]] && ok "zz-agent: not wrapped" || bad "zz-agent wrapped unexpectedly: '$l'"

[ "$(shasum "$EC_MANIFEST" | cut -d' ' -f1)" = "$before" ] && ok "manifest restored after --run" || bad "manifest left changed"

# Print mode: the printed line for a wrapped tag must be runnable as-is (README run-block form).
PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" >"$TMP/print.out" 2>&1
p=$(/usr/bin/grep -- "--tag performance-optimizer " "$TMP/print.out")
[[ "$p" == "bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval "* ]] \
  && ok "print mode: wrapped tag printed in the bash -c helper form" || bad "print mode perf line wrong: '$p'"
p=$(/usr/bin/grep -- "--tag zz-agent " "$TMP/print.out")
[[ "$p" == "claude plugin eval "* ]] && ok "print mode: unwrapped tag printed bare" || bad "print mode zz-agent line wrong: '$p'"

echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
