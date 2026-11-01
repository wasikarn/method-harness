#!/usr/bin/env bash
# test-eval-changed-judge.sh — the per-eval judge run scripts/eval-changed.sh adds for a case in
# evals/judge-models.tsv (GH #510), without model calls: a stub `claude` on PATH records each
# call's argv and whether defaultEnabled was true at that moment. The run must carry the case's
# own --allow-tools and load the plugin (with_default_enabled_true), or it scores a no-plugin
# fallback under the sonnet judge.
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
trap 'tmp_delete "$TMP"' EXIT

echo "=== eval-changed per-eval judge self-test ==="

R="$TMP/repo"
mkdir -p "$R/scripts/_lib" "$R/.claude-plugin" "$R/bin"
cp "$ROOT/scripts/eval-changed.sh" "$R/scripts/"
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$ROOT/scripts/_lib/eval_judge_models.py" "$R/scripts/_lib/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
case_md() {  # <case> <tags> <allowed_tools>
  mkdir -p "$R/evals/$1"
  printf -- '---\nname: %s\ntags: [%s]\nallowed_tools: [%s]\n---\nprompt\n' "$1" "$2" "$3" >"$R/evals/$1/prompt.md"
}
# Tags run in sorted order: ideate, zz-skill (two judge rows, so its inner loop has input left
# after the first call), zz-zz (a tag after both). With a stdin-reading claude, a dropped
# </dev/null on either call site (the tag run or the judge run) skips a later run.
case_md ideate-case "ideate" "Agent"
case_md zz-case "zz-skill, clean" "Bash, Read"
case_md zz-case3 "zz-skill" "Grep"
case_md zz-zz-case "zz-zz" "Read"
printf 'ideate-case\tfable\tGH #3\nzz-case\tsonnet\tGH #1\nzz-case3\topus\tGH #2\n' >"$R/evals/judge-models.tsv"
for t in ideate zz-skill zz-zz; do mkdir -p "$R/skills/x/$t"; echo a >"$R/skills/x/$t/SKILL.md"; done
git -C "$R" init -q && git -C "$R" add . && git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init \
  || { echo "test-eval-changed-judge: fixture commit failed" >&2; exit 1; }
for t in ideate zz-skill zz-zz; do echo b >>"$R/skills/x/$t/SKILL.md"; done

# The stub drains stdin, as a real claude can: without </dev/null on each call it would eat the
# rest of the script's here-string loops and later tags would silently not run.
cat >"$R/bin/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
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
for want in "--tag ideate " "--tag zz-skill " "--tag zz-zz " "--case ideate-case --judge-model fable" \
  "--case zz-case --judge-model sonnet" "--case zz-case3 --judge-model opus"; do
  /usr/bin/grep -q -- "$want" "$EC_LOG" \
    && ok "stdin-reading claude: '$want' still runs" || bad "stdin-reading claude: '$want' skipped: $(cat "$EC_LOG")"
done

# A broken sidecar or a missing module must stop the script before any paid run.
expect_no_runs() {  # <label>
  : >"$EC_LOG"
  if PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >/dev/null 2>&1; then
    bad "$1: --run exited 0"
  elif [ -s "$EC_LOG" ]; then
    bad "$1: claude ran before the failure: $(cat "$EC_LOG")"
  else
    ok "$1: exits non-zero before any claude call"
  fi
}
cp "$R/evals/judge-models.tsv" "$TMP/sidecar.good"
printf 'zz-case\tsonett\tGH #1\n' >"$R/evals/judge-models.tsv"
expect_no_runs "malformed judge-models.tsv"
cp "$TMP/sidecar.good" "$R/evals/judge-models.tsv"
mv "$R/scripts/_lib/eval_judge_models.py" "$TMP/"
expect_no_runs "missing eval_judge_models.py"
mv "$TMP/eval_judge_models.py" "$R/scripts/_lib/"
# An unreadable prompt.md passes `check` (it reads only sidecar cases' dirs) but makes the tag's
# allowed_tools lookup raise: without `|| exit 1` on it the tag would run with no --allow-tools.
mkdir -p "$R/evals/zz-bad"
printf -- '---\ntags: [ideate]\nallowed_tools: [Read]\n---\n\xff\xfe\n' >"$R/evals/zz-bad/prompt.md"
expect_no_runs "non-UTF-8 evals/zz-bad/prompt.md"
tmp_delete "$R/evals/zz-bad"

PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" >"$TMP/print.out" 2>&1
p=$(/usr/bin/grep -- "--case zz-case " "$TMP/print.out")
[[ "$p" == "bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval "*"--judge-model sonnet"*"'" ]] \
  && ok "print mode: judge run printed in the README's bash -c helper form" || bad "print mode judge line wrong: '$p'"

# A failing judge run must fail --run too, not vanish behind the tag run's success.
printf '#!/usr/bin/env bash\ncase " $* " in *" --case zz-case "*) exit 3 ;; esac\n' >"$R/bin/claude"
PATH="$R/bin:$PATH" bash "$R/scripts/eval-changed.sh" --run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "--run exits non-zero when the judge run fails (exit $rc)" || bad "--run exited 0 although the judge run failed"

echo "eval-changed per-eval judge self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
