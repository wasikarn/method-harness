#!/usr/bin/env bash
# test-eval-changed-judge.sh — the per-eval judge run scripts/eval-changed.sh adds for a case in
# evals/judge-models.tsv (GH #510), without model calls: a stub `claude` on PATH records each
# call's argv and whether defaultEnabled was true at that moment. The run must carry the case's
# own --allow-tools and load the plugin (with_default_enabled_true), or it scores a no-plugin
# fallback under the sonnet judge.
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
trap 'tmp_delete "$TMP"' EXIT

echo "=== eval-changed per-eval judge self-test ==="

R="$TMP/repo"
mkdir -p "$R/scripts/_lib" "$R/.claude-plugin" "$R/skills/x/zz-skill" "$R/evals/zz-case" "$R/bin"
cp "$ROOT/scripts/eval-changed.sh" "$R/scripts/"
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$ROOT/scripts/_lib/eval_judge_models.py" "$R/scripts/_lib/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
printf -- '---\nname: zz-case\ntags: [zz-skill, clean]\nallowed_tools: [Bash, Read]\n---\nprompt\n' >"$R/evals/zz-case/prompt.md"
printf 'zz-case\tsonnet\tGH #1\n' >"$R/evals/judge-models.tsv"
echo a >"$R/skills/x/zz-skill/SKILL.md"
git -C "$R" init -q && git -C "$R" add . && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init \
  || { echo "test-eval-changed-judge: fixture commit failed" >&2; exit 1; }
echo b >>"$R/skills/x/zz-skill/SKILL.md"

cat >"$R/bin/claude" <<'SH'
#!/usr/bin/env bash
en=$(/usr/bin/grep -o '"defaultEnabled": *[a-z]*' "$EC_MANIFEST" | sed 's/.*: *//')
echo "enabled=$en $*" >>"$EC_LOG"
SH
chmod +x "$R/bin/claude"
export EC_LOG="$TMP/calls.log" EC_MANIFEST="$R/.claude-plugin/plugin.json"
before=$(cat "$EC_MANIFEST")

PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >"$TMP/run.out" 2>"$TMP/run.err" \
  && ok "--run exits 0" || bad "--run exited non-zero: $(cat "$TMP/run.err")"
l=$(/usr/bin/grep -- "--case zz-case " "$EC_LOG")
[[ "$l" == *"--judge-model sonnet"*"--allow-tools Bash,Read"* ]] \
  && ok "judge run: --judge-model sonnet with the case's own --allow-tools" || bad "judge run argv wrong: '$l'"
[[ "$l" == enabled=true* ]] \
  && ok "judge run: plugin loaded (defaultEnabled true during the call)" || bad "judge run not wrapped: '$l'"
[ "$(cat "$EC_MANIFEST")" = "$before" ] && ok "manifest restored after --run" || bad "manifest left changed"

PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" >"$TMP/print.out" 2>&1
p=$(/usr/bin/grep -- "--case zz-case " "$TMP/print.out")
[[ "$p" == "bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval "*"--judge-model sonnet"*"'" ]] \
  && ok "print mode: judge run printed in the README's bash -c helper form" || bad "print mode judge line wrong: '$p'"

echo "eval-changed per-eval judge self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
