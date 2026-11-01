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

echo "=== eval-changed print-mode quoting self-test ==="

cat >"$TMP/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$EC_ARGS.$(( $(cat "$EC_N") ))"
echo $(( $(cat "$EC_N") + 1 )) >"$EC_N"
SH
chmod +x "$TMP/claude"
export EC_ARGS="$TMP/args" EC_N="$TMP/n"
mkdir -p "$TMP/stubbin" && cp "$TMP/claude" "$TMP/stubbin/"

# paste <shell> <line>: run <line> as a user pasting it into <shell> would. The interactive shells
# run in a new session (no controlling terminal): from a terminal's background job (merge-pr.sh &)
# they would try to take the terminal and be stopped, hanging the gauntlet. python3, as macOS
# has no setsid(1). It forks first: setsid() fails (EPERM) in a process-group leader.
NO_TTY='
import os, signal, sys
pid = None
def stop(sig, _):
    # The shell has its own session, so a Ctrl-C or hangup sent to the test reaches only this parent:
    # hang up the shell first (an interactive shell ignores TERM), then die of the same signal (GH #806).
    if pid:
        for kill in (os.killpg, os.kill):  # os.kill: the child has not run setsid() yet
            try:
                kill(pid, signal.SIGHUP); break
            except OSError:
                pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    signal.signal(sig, signal.SIG_DFL); os.kill(os.getpid(), sig)
sigs = {s for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP) if signal.getsignal(s) != signal.SIG_IGN}
for s in sigs:
    signal.signal(s, stop)
# Blocked across fork(): a signal handled while fork() returns would see pid unset and orphan the child.
signal.pthread_sigmask(signal.SIG_BLOCK, sigs)
pid = os.fork()
signal.pthread_sigmask(signal.SIG_UNBLOCK, sigs)
if pid == 0:
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
_, st = os.waitpid(pid, 0)
pid = None  # reaped: a late signal must not hit a reused pid
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)'
no_tty() { python3 -c "$NO_TTY" "$@"; }
paste_in() {
  case "$1" in
    bash-c) bash -c "$2" ;;
    bash-i) HISTFILE=/dev/null no_tty bash --norc --noprofile -i <<<"$2" 2>&1 ;;
    # zsh -f still reads /etc/zshenv, which may rebuild PATH: restate it first, so the paste
    # reaches the stub claude and never a real one.
    zsh-i) HISTFILE=/dev/null no_tty zsh -f -i <<<"PATH=$(printf '%q' "$PATH")"$'\n'"$2" ;;
  esac
}
# GH #806: a Ctrl-C or hangup sent to the test reaches only no_tty's python parent, as the shell has
# its own session. The shell must end with it: an orphan keeps reading the paste after the EXIT trap
# has deleted the stub claude, so a later line can start a real, paid one. The kill waits until the
# shell is reading the paste, or it would land before the fork and test nothing.
mark="$TMP/orphan-ran" started="$TMP/paste-started"
HISTFILE=/dev/null python3 -c "$NO_TTY" bash --norc --noprofile -i \
  <<<": >$(printf '%q' "$started"); sleep 1; : >$(printf '%q' "$mark")" >/dev/null 2>&1 &
p=$!
for _ in $(seq 50); do [ -e "$started" ] && break; sleep 0.1; done
[ -e "$started" ] || bad "the no_tty paste did not start within 5 s"
kill -TERM "$p"; wait "$p"; sleep 1.5
[ ! -e "$mark" ] && ok "a SIGTERM to no_tty ends the pasted shell too" \
  || bad "a SIGTERM to no_tty left the pasted shell running: it ran the rest of the paste"

# GH #803: every non-interactive bash reads $BASH_ENV first, so a file there that prepends the real
# claude's dir to PATH would put it ahead of the stub. All three eval-changed tests must unset it.
for t in test-eval-changed-print.sh test-eval-changed.sh test-eval-changed-judge.sh; do
  awk '/^unset / { f = 1; exit !(/ BASH_ENV( |$)/ && / ENV( |$)/) } END { if (!f) exit 1 }' "$HERE/$t" \
    && ok "$t unsets BASH_ENV and ENV on its first unset line" \
    || bad "$t does not unset BASH_ENV and ENV on its first unset line"
done

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
  # The whole printed block, hint line included, as a user pastes it: both runs must happen. With
  # zsh's default (no interactivecomments) a `# ...; read ...` hint ran `read`, which swallowed
  # the judge line below it.
  for sh in $shells; do
    echo 0 >"$EC_N"; : >"$EC_ARGS.0"; : >"$EC_ARGS.1"
    (cd "$R" && PATH="$R/bin:$PATH" paste_in "$sh" "$(cat "$TMP/print.out")") >"$TMP/paste.out" 2>&1
    if /usr/bin/grep -qx -- '--tag' "$EC_ARGS.0" && /usr/bin/grep -qx -- '--case' "$EC_ARGS.1"; then
      ok "$1: the whole printed block pasted into $sh runs the tag run, then the judge run"
    else
      bad "$1: the whole printed block pasted into $sh: $(cat "$EC_N") claude call(s); output: $(cat "$TMP/paste.out")"
    fi
  done
}

# A paste must reach the stub claude, never a real one: zsh -f still reads /etc/zshenv, and one
# that rebuilds PATH (or a BASH_ENV file, for bash -c) would make the paste checks below paid eval runs.
for sh in $shells; do
  got=$(PATH="$TMP/stubbin:$PATH" paste_in "$sh" 'command -v claude' 2>&1)
  /usr/bin/grep -qF "$TMP/stubbin/claude" <<<"$got" && ok "$sh resolves claude to the stub on the paste's PATH" \
    || { bad "$sh does not resolve claude to the stub (a zshenv or rc file reset PATH): $got"; exit 1; }
done

# The tag run's list is the sorted union over the tag's cases; the judge run keeps frontmatter order.
check_fixture apostrophe 'Bash(git log:*), Read, $(touch${IFS}PWNED), it'\''s' \
  '$(touch${IFS}PWNED),Bash(git log:*),Read,it'\''s' 'Bash(git log:*),Read,$(touch${IFS}PWNED),it'\''s' sonnet
# No apostrophe: in the fixture above, a reverted script's paste is a syntax error at `it's`
# before the other entries are checked, so a fix that quoted only lines holding ' would pass it.
check_fixture no-apostrophe 'Bash(git log:*), Read, $(touch${IFS}PWNED), !!' \
  '!!,$(touch${IFS}PWNED),Bash(git log:*),Read' 'Bash(git log:*),Read,$(touch${IFS}PWNED),!!' 'opus[1m]'

# evals/README.md's run block, pasted whole into each shell as its readers do (it tells zsh users
# to paste there), must run every line. In zsh without interactivecomments a `#` comment is a
# command: a trailing `# ... (...)` made its whole line a parse error, skipping that run.
RB="$TMP/readme-block"
mkdir -p "$RB/scripts/_lib" "$RB/.claude-plugin" "$RB/bin"
cp "$ROOT/scripts/_lib/eval-default-enabled.sh" "$RB/scripts/_lib/"
cp "$TMP/claude" "$RB/bin/"
printf '{\n  "name": "mh",\n  "defaultEnabled": false\n}\n' >"$RB/.claude-plugin/plugin.json"
block=$(awk '/^Run \(needs Claude Code/ {r=1} r && /^```bash$/ {b=1; next} b && /^```$/ {exit} b' "$ROOT/evals/README.md")
want=$(/usr/bin/grep -c '^bash -c ' <<<"$block")
[ "$want" -gt 0 ] || bad "evals/README.md: run block not found"
for sh in $shells; do
  echo 0 >"$EC_N"
  (cd "$RB" && PATH="$RB/bin:$PATH" paste_in "$sh" "$block") >"$TMP/paste.out" 2>&1
  [ "$(cat "$EC_N")" -eq "$want" ] \
    && ok "evals/README.md run block pasted into $sh runs all $want lines" \
    || bad "evals/README.md run block pasted into $sh: $(cat "$EC_N") of $want lines ran: $(/usr/bin/grep -i 'error\|not found' "$TMP/paste.out" | head -3)"
done

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
