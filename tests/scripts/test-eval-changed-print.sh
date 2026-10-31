#!/usr/bin/env bash
# test-eval-changed-print.sh — the `bash -c '...'` lines scripts/eval-changed.sh prints (every tag
# run and judge run, since GH #773) must paste back as exactly the argv --run would use.
# Their --allow-tools value comes from prompt.md frontmatter, which nothing validates: a scoped
# tool like `Bash(git log:*)` must survive as one argument, and shell syntax in it must not run.
# Each printed line is pasted into bash -c, an interactive bash (history expansion on), and an
# interactive zsh when installed (evals/README.md's users paste there), with a stub `claude`
# that logs one argument per line.
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

cat >"$TMP/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$EC_ARGS.$(( $(cat "$EC_N") ))"
echo $(( $(cat "$EC_N") + 1 )) >"$EC_N"
SH
chmod +x "$TMP/claude"
export EC_ARGS="$TMP/args" EC_N="$TMP/n"

# paste <shell> <line>: run <line> as a user pasting it into <shell> would.
paste_in() {
  case "$1" in
    bash-c) bash -c "$2" ;;
    bash-i) HISTFILE=/dev/null bash --norc --noprofile -i <<<"$2" 2>&1 ;;
    zsh-i) HISTFILE=/dev/null zsh -f -i <<<"$2" ;;
  esac
}
shells="bash-c bash-i"
if command -v zsh >/dev/null 2>&1; then shells="$shells zsh-i"; else echo "  SKIP: zsh not installed, no zsh paste"; fi

# check_fixture <name> <allowed_tools list> <want tag --allow-tools> <want judge --allow-tools> <judge model>
check_fixture() {
  local R="$TMP/$1" kind want_allow line sh got
  mkdir -p "$R/scripts/_lib" "$R/.claude-plugin" "$R/bin" "$R/skills/x/ideate" "$R/evals/ideate-case"
  cp "$ROOT/scripts/eval-changed.sh" "$R/scripts/"
  cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$ROOT/scripts/_lib/eval_judge_models.py" "$R/scripts/_lib/"
  cp "$TMP/claude" "$R/bin/"
  printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$R/.claude-plugin/plugin.json"
  # The case also has a judge row, so both the tag line and the judge line are printed.
  printf -- '---\nname: ideate-case\ntags: [ideate]\nallowed_tools: [%s]\n---\nprompt\n' "$2" >"$R/evals/ideate-case/prompt.md"
  printf 'ideate-case\t%s\tGH #1\n' "$5" >"$R/evals/judge-models.tsv"
  echo a >"$R/skills/x/ideate/SKILL.md"
  : >"$R/opusm"  # an unquoted opus[1m] would glob to it
  git -C "$R" init -q && git -C "$R" add . \
    && git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init \
    || { bad "$1: fixture commit failed"; return; }
  echo b >>"$R/skills/x/ideate/SKILL.md"
  (cd "$R" && PATH="$R/bin:$PATH" bash scripts/eval-changed.sh >"$TMP/print.out" 2>"$TMP/print.err") \
    || { bad "$1: print mode exited non-zero: $(cat "$TMP/print.err")"; return; }
  for kind in "--tag ideate" "--case ideate-case"; do
    case "$kind" in --tag*) want_allow=$3 ;; *) want_allow=$4 ;; esac
    line=$(/usr/bin/grep -F -- "$kind " "$TMP/print.out")
    case "$line" in "bash -c "*) ;; *) bad "$1: $kind: not printed in the bash -c form: '$line'"; continue ;; esac
    for sh in $shells; do
      echo 0 >"$EC_N"; : >"$EC_ARGS.0"
      (cd "$R" && PATH="$R/bin:$PATH" paste_in "$sh" "$line") >"$TMP/paste.out" 2>&1 \
        || { bad "$1: $kind: the printed line fails when pasted into $sh: $(cat "$TMP/paste.out")"; continue; }
      got=$(/usr/bin/grep -A1 -x -- '--allow-tools' "$EC_ARGS.0" | tail -n 1)
      [ "$got" = "$want_allow" ] \
        && ok "$1: $kind: --allow-tools pastes back into $sh as one argument, verbatim" \
        || bad "$1: $kind: --allow-tools pasted into $sh as '$got', want '$want_allow'"
      if [ "$kind" = "--case ideate-case" ]; then
        got=$(/usr/bin/grep -A1 -x -- '--judge-model' "$EC_ARGS.0" | tail -n 1)
        [ "$got" = "$5" ] && ok "$1: --judge-model $5 pastes back into $sh verbatim" \
          || bad "$1: --judge-model pasted into $sh as '$got', want '$5'"
      fi
      [ ! -e "$R/PWNED" ] && ok "$1: $kind: shell syntax in allowed_tools does not run when pasted into $sh" \
        || { bad "$1: $kind: pasting the printed line into $sh ran \$(touch PWNED)"; tmp_delete "$R/PWNED"; }
    done
  done
}

# The tag run's list is the sorted union over the tag's cases; the judge run keeps frontmatter order.
check_fixture apostrophe 'Bash(git log:*), Read, $(touch${IFS}PWNED), it'\''s' \
  '$(touch${IFS}PWNED),Bash(git log:*),Read,it'\''s' 'Bash(git log:*),Read,$(touch${IFS}PWNED),it'\''s' sonnet
# No apostrophe: in the fixture above, a reverted script's paste is a syntax error at `it's`
# before the other entries are checked, so a fix that quoted only lines holding ' would pass it.
check_fixture no-apostrophe 'Bash(git log:*), Read, $(touch${IFS}PWNED), !!' \
  '!!,$(touch${IFS}PWNED),Bash(git log:*),Read' 'Bash(git log:*),Read,$(touch${IFS}PWNED),!!' 'opus[1m]'

# shell_word itself: every word must read back verbatim, trailing newlines included ($(...) strips
# them, so a version built on command substitution prints $'x\n' as 'x').
eval "$(sed -n '/^shell_word() {/,/^}/p' "$ROOT/scripts/eval-changed.sh")"
for w in '' plain "it's" "''" $'x\n' $'\n\n' $'a\nb' '$(x)' '!!' 'a b'; do
  eval "got=$(shell_word "$w")"
  [ "$got" = "$w" ] && ok "shell_word round-trips $(printf '%q' "$w")" \
    || bad "shell_word: $(printf '%q' "$w") reads back as $(printf '%q' "$got")"
done

echo "eval-changed print-mode quoting self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
