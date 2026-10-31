#!/usr/bin/env bash
# test-eval-changed-print.sh — the `bash -c '...'` lines scripts/eval-changed.sh prints for tags
# and judge runs that need the plugin loaded must paste back as exactly the argv --run would use.
# Their --allow-tools value comes from prompt.md frontmatter, which nothing validates: a scoped
# tool like `Bash(git log:*)` must survive as one argument, and shell syntax in it must not run.
# Each printed line is run through bash with a stub `claude` that logs one argument per line.
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

echo "=== eval-changed print-mode quoting self-test ==="

R="$TMP/repo"
mkdir -p "$R/scripts/_lib" "$R/.claude-plugin" "$R/bin" "$R/skills/x/ideate"
cp "$ROOT/scripts/eval-changed.sh" "$R/scripts/"
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$ROOT/scripts/_lib/eval_judge_models.py" "$R/scripts/_lib/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
mkdir -p "$R/evals/ideate-case"
# ideate is one of the tags eval-changed.sh wraps; the case also has a judge row, so both the
# tag line and the judge line are printed in the bash -c form.
printf -- '---\nname: ideate-case\ntags: [ideate]\nallowed_tools: [Bash(git log:*), Read, $(touch${IFS}PWNED)]\n---\nprompt\n' \
  >"$R/evals/ideate-case/prompt.md"
printf 'ideate-case\tsonnet\tGH #1\n' >"$R/evals/judge-models.tsv"
echo a >"$R/skills/x/ideate/SKILL.md"
git -C "$R" init -q && git -C "$R" add . && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init \
  || { echo "test-eval-changed-print: fixture commit failed" >&2; exit 1; }
echo b >>"$R/skills/x/ideate/SKILL.md"

cat >"$R/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$EC_ARGS.$(( $(cat "$EC_N") ))"
echo $(( $(cat "$EC_N") + 1 )) >"$EC_N"
SH
chmod +x "$R/bin/claude"
export EC_ARGS="$TMP/args" EC_N="$TMP/n"
echo 0 >"$EC_N"

(cd "$R" && PATH="$R/bin:$PATH" bash scripts/eval-changed.sh >"$TMP/print.out" 2>"$TMP/print.err") \
  || { bad "print mode exited non-zero: $(cat "$TMP/print.err")"; }
# The tag run's list is the sorted union over the tag's cases; the judge run keeps frontmatter order.
for kind in "--tag ideate" "--case ideate-case"; do
  case "$kind" in
    --tag*) want_allow='$(touch${IFS}PWNED),Bash(git log:*),Read' ;;
    *) want_allow='Bash(git log:*),Read,$(touch${IFS}PWNED)' ;;
  esac
  line=$(/usr/bin/grep -F -- "$kind " "$TMP/print.out")
  case "$line" in "bash -c "*) ;; *) bad "$kind: not printed in the bash -c form: '$line'"; continue ;; esac
  echo 0 >"$EC_N"
  (cd "$R" && PATH="$R/bin:$PATH" bash -c "$line") >"$TMP/paste.out" 2>&1 \
    || { bad "$kind: the printed line fails when pasted: $(cat "$TMP/paste.out")"; continue; }
  got=$(/usr/bin/grep -A1 -x -- '--allow-tools' "$EC_ARGS.0" | tail -n 1)
  [ "$got" = "$want_allow" ] \
    && ok "$kind: --allow-tools pastes back as one argument, verbatim" \
    || bad "$kind: --allow-tools pasted as '$got', want '$want_allow'"
  [ ! -e "$R/PWNED" ] && ok "$kind: shell syntax in allowed_tools does not run when pasted" \
    || { bad "$kind: pasting the printed line ran \$(touch PWNED)"; tmp_delete "$R/PWNED"; }
done

echo "eval-changed print-mode quoting self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
