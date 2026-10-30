#!/usr/bin/env bash
# Behavioral tests for hooks/gates/subagent-git-guard.sh (issue #135).
# Run standalone: bash tests/hooks/test-subagent-git-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
# Isolate the gate-verdict journal (hooks/gates/_journal.py) from this file's
# deny assertions -- run standalone (this file's own header invites it), it
# would otherwise silently append rows to the operator's real
# ~/.local/share/kbg/metrics/gate-decisions.jsonl.
_JOURNAL_TMP="$(mktemp -d)"
trap 'tmp_delete "$_JOURNAL_TMP"' EXIT
export MH_GATE_JOURNAL_PATH="$_JOURNAL_TMP/gate-decisions.jsonl"
GATE="$ROOT/hooks/gates/subagent-git-guard.sh"
# The length cap (GH #469) would decide every over-16000-character stress row below before its scan ran; lift it
# for the file and let the cap rows unset it.
export MH_SGG_MAX_CMD_CHARS=100000000
# The deadline (GH #469) would turn a slow stress row below into a deny before its scan finished; lift it too.
export MH_SGG_DEADLINE_SECS=1000

pass=0
fail=0

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

payload() { # payload <command> [agent_id]
  python3 -c '
import json, sys
d = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}
if len(sys.argv) > 2 and sys.argv[2]:
    d["agent_id"] = sys.argv[2]
    d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "${2:-}"
}

run_gate() { # run_gate <command> [agent_id]
  echo "$(payload "$1" "${2:-}")" | bash "$GATE" 2>/dev/null
}

# payload_forced_id <command> <agent_id_raw>: agent_id KEY always present,
# even at "" or the literal __NULL__ (JSON null) -- payload() above treats a
# falsy $2 as "omit the key" (main session shape), which cannot express
# "key present but empty/null" (the same GH #154/#155 truthiness gap fixed
# elsewhere: `if not agent_id` treats presence-with-empty/null as absence).
payload_forced_id() {
  python3 -c '
import json, sys
cmd, agent_id_raw = sys.argv[1], sys.argv[2]
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "$2"
}

run_gate_forced_id() { # run_gate_forced_id <command> <agent_id_raw>
  echo "$(payload_forced_id "$1" "$2")" | bash "$GATE" 2>/dev/null
}

echo "=== subagent-git-guard gate ==="

# --- (1) main session (no agent_id) is untouched, even for the exact
# incident command --- #
run_gate "git stash" ""; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "main session: git stash allowed (no agent_id)" "$ok"

# --- (2) subagent: every uncovered destructive shape denies (exit 2) --- #
for cmd in \
  "git stash" \
  "git stash pop" \
  "git reset" \
  "git reset --soft HEAD^" \
  "git clean -n"
do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "subagent denied: $cmd" "$ok"
done

# --- (2b) GH #157 sibling: an escaped quote outside a span must not mask
# the real "git stash" after it (was a bypass, false ALLOW) --- #
run_gate 'echo \" ; git stash' "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: echo \\\" ; git stash (escaped quote before a real stash)" "$ok"
run_gate "echo \\' ; git stash" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: echo \\' ; git stash (escaped single quote before a real stash)" "$ok"
run_gate 'echo "a ; b" ; git stash' "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: real double-quoted span then a real stash" "$ok"
run_gate "echo '\\' ; git stash" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: backslash inside single quotes is literal, span closes, real stash follows" "$ok"
run_gate 'echo "\" ; git stash"' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "subagent allowed: stash inside a real double-quoted span (escaped quote inside the span)" "$ok"

# --- (2c) GH #161: ANSI-C $'\'' is one complete string; the old masker
# opened a fake single-quote span at the escaped apostrophe and masked the
# real "git stash" away (false ALLOW) --- #
run_gate "echo \$'\\'' ; git stash" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: echo \$'\\'' ; git stash (ANSI-C span before a real stash)" "$ok"
run_gate "echo \$'a ; git stash'" "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "subagent allowed: stash inside an ANSI-C \$'...' span" "$ok"
# Backslash-newline at a word start is masked as blanks (GH #286, was a
# boundary since validator round 2), so `\<nl>git stash`, a real stash, still
# reaches _ANCHOR_RE and the three real-stash shapes must deny. `echo
# \<nl>git stash` is really `echo git stash`, so it is now allowed.
run_gate $'echo \\\ngit stash' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "subagent allowed (git is echo's argument): echo \\<nl>git stash" "$ok"
for cmd in $'\\\ngit stash' $'echo; \\\ngit stash' $'env \\\ngit stash'; do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "subagent denied: real stash after a backslash-newline: $(printf '%q' "$cmd")" "$ok"
done
# Round 2: an escaped "\$" or a "$$" PID before a plain single-quoted string
# must not open an ANSI-C span whose "\'" swallows the real stash.
run_gate "\\\$'a\\'; git stash; echo 'x'" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: \\\$'a\\'; git stash; echo 'x' (escaped \$, plain single quotes)" "$ok"
run_gate "\$\$'a\\'; git stash; echo 'x'" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "subagent denied: \$\$'a\\'; git stash; echo 'x' (PID, plain single quotes)" "$ok"

# --- (3) subagent: unrelated git/non-git commands allowed --- #
for cmd in \
  "git status" \
  "git diff" \
  "git add foo.txt" \
  'git commit -m "add feature"' \
  "ls"
do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 0 ] && ok=0
  check "subagent allowed (unrelated): $cmd" "$ok"
done

# --- (4) false-positive guards: git verb text inside prose/quotes must not
# trip the gate --- #
run_gate 'git commit -m "explain why git stash is unsafe here"' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "false positive: commit message mentioning git stash allowed" "$ok"

run_gate 'grep -r "git reset" docs/' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "false positive: grep for \"git reset\" allowed" "$ok"

run_gate 'echo "git checkout -- x"' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "false positive: echo of a checkout -- string allowed" "$ok"

# --- (5) checkout is intentionally NOT this gate's job: hooks/gates/irrecoverable.sh
# already denies the discard forms (--/./-f/2+ nonflag args) unconditionally for
# EVERY session, including main -- re-implementing that here would duplicate an
# existing unconditional deny. A plain branch-switch checkout stays allowed either
# way. Verified here in isolation (this gate alone), not through the full gate
# chain -- irrecoverable.sh is owned by a concurrent session and out of scope. --- #
run_gate "git checkout -- foo.txt" "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "checkout -- not handled by this gate (covered by gate:bash:irrecoverable instead)" "$ok"

run_gate "git checkout HEAD -- foo.txt" "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "checkout HEAD -- not handled by this gate (covered by gate:bash:irrecoverable instead)" "$ok"

run_gate "git checkout main" "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "plain branch-switch checkout allowed" "$ok"

# --- (6) restore is likewise NOT this gate's job for the same reason: irrecoverable.sh
# already denies any pathspec targeting the worktree, unconditionally, for every session.
run_gate "git restore foo.txt" "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "restore not handled by this gate (covered by gate:bash:irrecoverable instead)" "$ok"

# --- (7) global-flag bypass fix (2026-09-04, verifier-found): a git global
# flag between "git" and the subcommand used to slip the subcommand check
# entirely (dm was tried against "-C"/"--no-pager"/etc instead of the real
# verb). Must all deny now. --- #
for cmd in \
  "git -C /repo stash" \
  "git --no-pager clean -d" \
  "git -c core.x=y reset" \
  "git --git-dir=.git stash"
do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "global-flag bypass fixed, now denied: $cmd" "$ok"
done

# --- (8) sudo/xargs wrapper (2026-09-04, verifier-found second half of the
# same bug): deliberately fixed rather than left as a documented non-goal --
# the anchor now walks past an optional leading sudo/xargs wrapper too. --- #
for cmd in \
  "sudo git stash" \
  "xargs git stash" \
  "sudo -u someuser git stash"
do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "sudo/xargs wrapper fixed, now denied: $cmd" "$ok"
done

# --- (8b) 2026-09-20 audit: the sudo/xargs wrapper fix above was single-level
# and had a narrower wrapper vocabulary than irrecoverable.py's. A chained
# wrapper (env sudo git ...) or a backslash-escaped \git bypassed the anchor
# live, and the wrapper set didn't include env/command/nohup/nice/time. --- #
for cmd in \
  "env git stash" \
  "env sudo git stash" \
  "\git stash" \
  "nohup git stash" \
  "nice git stash" \
  "time git stash" \
  "command git stash"
do
  run_gate "$cmd" "agent1"; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "wrapper-chain bypass fixed, now denied: $cmd" "$ok"
done

# --- (8c) compliance-audit fix-round 2, 2026-09-20: a first fix bounded the
# wrapper chain at depth<=3 to dodge a catastrophic-backtracking shape; an
# independent verifier chained 13 wrappers and got past that cap live. --- #
long_chain="$(python3 -c 'print("env sudo nohup nice time command " * 13 + "git reset --hard")')"
run_gate "$long_chain" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "13-deep wrapper chain past the old depth<=3 bound, now denied" "$ok"

run_gate "env -u A -u B git reset --hard" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "env with its own -u flags before git reset, now denied" "$ok"

# --- (9) missing re.MULTILINE fix (2026-09-04, verifier-found): a genuine
# multi-line Bash command (heredoc/multi-line script) puts "git reset" at
# the start of its OWN line, not absolute string offset 0 -- the old
# anchor only matched offset 0 and silently allowed this. Uses printf for
# a real embedded newline, not echo, since echo's backslash-escape
# behavior differs across shells (zsh interprets \n by default; bash does
# not -- caught live while verifying this fix). --- #
run_gate "$(printf 'ls\ngit reset')" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "multi-line command: git reset at start of its own line now denied" "$ok"

# --- (10) quote-aware anchor fix (2026-09-04, verifier-found false
# positive): a `;`/`&`/`|`/`(` sitting INSIDE a quoted argument used to be
# treated as a real command-separator anchor, wrongly denying an ordinary
# safe command. Must now allow. --- #
run_gate 'git commit -m "fix; git reset was wrong"' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "false positive fixed: separator inside quotes no longer anchors" "$ok"

run_gate 'echo "a; git stash"' "agent1"; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "false positive fixed: quoted prose with a git verb allowed" "$ok"

# --- (10b) 2026-09-20 audit: agent_id truthiness bug -- an empty-string or
# null agent_id (key present, value falsy) was treated as "not a subagent"
# by `agent_id = d.get("agent_id"); if not agent_id: sys.exit(0)`, letting a
# destructive git command through unguarded. Must deny like any other
# subagent call. --- #
run_gate_forced_id "git stash" ""; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "agent_id truthiness bug: empty-string agent_id still denied" "$ok"

run_gate_forced_id "git stash" "__NULL__"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "agent_id truthiness bug: JSON null agent_id still denied" "$ok"

# --- (10c) deep-audit fix-round 3, 2026-09-20: _mask_quotes had no "#"
# comment awareness -- an ordinary comment apostrophe ("# don't remove")
# BEFORE a real git command opened an unterminated fake single-quote span
# (no closing "'" anywhere after it), masking every real char after it,
# including the literal "git" anchor -- live-confirmed full bypass of this
# entire gate for any dangerous subcommand, not just one flag. --- #
apostrophe_cmd="$(printf "echo hi # don't remove\ngit reset --hard")"
run_gate "$apostrophe_cmd" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "comment-apostrophe bypass fixed: git reset --hard after a # don't comment now denied" "$ok"

# Comment AFTER the real git call must still deny too (control: the fix must
# not swallow the anchor when the apostrophe comes later on the same line).
run_gate "git reset --hard # don't undo this" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "comment-apostrophe control: apostrophe after the anchor still denies" "$ok"

# 2026-09-21 deep-audit: ")" was missing from the masker's word-boundary set,
# so "(true)#don't" did not open a comment and its apostrophe swallowed the
# real "git stash" on the next line into a fake quote span -- silent ALLOW.
paren_comment_cmd="$(printf "(true)#don't\ngit stash")"
run_gate "$paren_comment_cmd" "agent1"; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "comment right after ')' then git stash on the next line: denied (was silently ALLOWed)" "$ok"

# --- (11) malformed/non-JSON stdin: fail-safe allow --- #
out=$(echo "not json" | bash "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "malformed stdin: fail-safe allow, exit 0, no stdout" "$ok"

# --- (12) spelling variants (GH #213): the same denied verbs behind a wrapper the anchor did not
# know, a shell keyword, a bash -c / eval body, or a git global flag with a separate value --- #
sgg_rc() { payload "$1" fork | bash "$GATE" >/dev/null 2>&1; echo $?; }
for _c in \
  'exec git stash' \
  'timeout 5 git stash' \
  'gtimeout 5 git stash' \
  'setsid git stash' \
  'stdbuf -oL git stash' \
  'ionice -c3 git stash' \
  'env timeout=30 git stash' \
  'for i in 1; do git stash; done' \
  'while true; do git reset HEAD~1; done' \
  'until false; do git clean -n; done' \
  'if true; then git stash; fi' \
  'if false; then :; else git stash; fi' \
  '! git stash' \
  'coproc git stash' \
  'bash -c "git stash"' \
  "sh -c 'git stash'" \
  'zsh -lc "git reset HEAD~1"' \
  'sudo bash -c "git stash"' \
  'eval "git stash"' \
  'git --namespace x stash' \
  'git --attr-source HEAD stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "spelling variant denied for a subagent: $_c" "$ok"
done
for _c in \
  'echo do git stash' \
  'git commit -m "then git stash"' \
  'git commit -m "run bash -c '"'"'git stash'"'"'"' \
  'bash -c "git status"' \
  'bash -c "git stash list"' \
  'timeout 5 git status' \
  'env timeout=30 git status' \
  'for i in 1; do git stash list; done' \
  'eval "git status"' \
  'git --namespace x status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "spelling-variant control allowed for a subagent: $_c" "$ok"
done

# --- (13) deep-audit 4 (2026-09-29): unquoted eval / builtin, and the rtk wrapper that
# irrecoverable.py's shared list gained (GH #216) while this file kept its own copy --- #
for _c in \
  'eval git stash' \
  'eval git reset --hard' \
  'eval git clean -fd' \
  'eval eval git stash' \
  'eval command git stash' \
  'builtin command git stash' \
  'builtin eval git stash' \
  'builtin exec git stash' \
  'eval exec git stash' \
  'eval -- git stash' \
  'rtk run git stash' \
  'rtk run --skip-env git stash' \
  'rtk proxy -- git stash' \
  'eval "eval git stash"' \
  "sh -c 'eval git stash'" \
  'rtk git stash' \
  'rtk proxy git stash' \
  'rtk proxy git reset --hard' \
  'rtk -v proxy git stash' \
  'rtk err git stash' \
  'rtk test git stash' \
  'rtk summary git stash' \
  "rtk run -c 'git stash'" \
  'rtk run --command "git reset --hard"' \
  'rtk run "git stash"' \
  'rtk err "git clean -fd"' \
  'rtk test "git stash"' \
  'rtk summary "git reset --hard"' \
  'rtk -v run "git stash"' \
  'rtk run --skip-env -c "git stash"' \
  "rtk run --command='git stash'" \
  'rtk run -- "git stash"' \
  'rtk run --ultra-compact "git reset HEAD~1"' \
  'rtk err --skip-env "git clean -fd"' \
  'rtk test --ultra-compact "git stash"' \
  'env eval=1 git stash' \
  'env builtin=1 git stash' \
  'env rtk=1 git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "eval/builtin/rtk spelling denied for a subagent: $_c" "$ok"
done
for _c in \
  'eval git status' \
  'eval git stash list' \
  'eval echo "git stash"' \
  'builtin echo hi' \
  'rtk git status' \
  'rtk proxy git stash list' \
  "rtk run -c 'git status'" \
  "rtk run --command='git status'" \
  'rtk grep "git stash" docs' \
  'eval=1 git status' \
  'builtin=1 git status' \
  'rtk=1 git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "eval/builtin/rtk control allowed for a subagent: $_c" "$ok"
done

# --- (14) GH #273: a chain word (eval, rtk, rtk proxy) before a wrapper word --- #
for _c in \
  'eval sudo git stash' \
  'eval time git stash' \
  'eval env A=1 git clean -fd' \
  'eval nice -n 5 git stash' \
  'eval doas git stash' \
  'rtk proxy sudo git stash' \
  'rtk proxy time git stash' \
  'rtk proxy env A=1 git reset --hard' \
  'builtin eval sudo git stash' \
  'eval -- sudo git stash' \
  'true; eval sudo git stash; git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "chain word before a wrapper denied for a subagent: $_c" "$ok"
done
for _c in \
  'eval sudo git status' \
  'eval time git stash list' \
  'eval env A=1 git diff' \
  'rtk proxy sudo git log' \
  "eval sudo echo \"'git stash'\"" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "chain word before a wrapper control allowed for a subagent: $_c" "$ok"
done
# GH #327: eval re-parses its words, so `eval sudo echo "git stash"` is read as `sudo echo git stash`,
# which the wrapper walk denies like the plain text (sudo's arguments are skipped). The control above
# keeps the string quoted through both parses. Deny-biased, accepted.
rc=$(sgg_rc 'eval sudo echo "git stash"'); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #327: eval sudo echo \"git stash\" reads like sudo echo git stash (denied, over-deny accepted)" "$ok"
# Worst case stays fast: long runs of chain words and wrappers, in both orders.
_lc1=$(python3 -c 'print("true; " + "eval sudo " * 3000 + "git stash")')
_lc2=$(python3 -c 'print("rtk proxy time " * 3000 + "git status")')
_t0=$(date +%s)
rc=$(sgg_rc "$_lc1"); check "long eval-sudo run still denied (rc=$rc)" "$([ "$rc" = "2" ] && echo 0 || echo 1)"
rc=$(sgg_rc "$_lc2"); check "long rtk-proxy-time run allowed (rc=$rc)" "$([ "$rc" = "0" ] && echo 0 || echo 1)"
_dt=$(( $(date +%s) - _t0 ))
check "long chain-before-wrapper runs took ${_dt}s (<6s)" "$([ "$_dt" -lt 6 ] && echo 0 || echo 1)"

# Drift guard: every wrapper word in irrecoverable.py's PREFIX_WRAPPERS must also be a wrapper
# here (the two lists are typed by hand, GH #213). irrecoverable.py runs on import, so the two
# tuples are read from its source. A parse failure yields no words and fails the count check.
_wrappers=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import ast, sys
env = {}
for n in ast.parse(open(sys.argv[1]).read()).body:
    if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in ("FLAG_VALUE_WRAPPERS", "PREFIX_WRAPPERS"):
        exec(compile(ast.Module([n], []), "irrecoverable.py", "exec"), env)
print(*env.get("PREFIX_WRAPPERS", ()))
PY
)
_n=0; for _w in $_wrappers; do _n=$((_n + 1)); done
ok=1; [ "$_n" -ge 8 ] && ok=0
check "drift guard read $_n wrapper words from irrecoverable.py PREFIX_WRAPPERS (expect at least 8)" "$ok"
for _w in $_wrappers; do
  rc=$(sgg_rc "$_w git stash"); ok=1; [ "$rc" = "2" ] && ok=0
  check "irrecoverable wrapper word is a wrapper in the guard too: $_w git stash" "$ok"
  # command and exec are also in the guard's bounded chain, which hides their removal from the wrapper
  # list when the flag is absent; a flag before the command word only the wrapper walk can skip.
  rc=$(sgg_rc "$_w -x git stash"); ok=1; [ "$rc" = "2" ] && ok=0
  check "irrecoverable wrapper word is a wrapper in the guard too, flag before the command: $_w -x git stash" "$ok"
  # GH #320: a wrapper written as a path runs the same program (`/usr/bin/env git stash`).
  rc=$(sgg_rc "/usr/bin/$_w git stash"); ok=1; [ "$rc" = "2" ] && ok=0
  check "irrecoverable wrapper word written as a path is a wrapper in the guard too: /usr/bin/$_w git stash" "$ok"
done

# --- (14) eval / builtin / rtk must not hide the statements after them (deep-audit 4, whole-picture
# pass). Putting them in the wrapper list made the greedy argument walk run across `;` / `&&` /
# newlines to the last `git`, so these went from denied to allowed. They now take a bounded prefix
# that never walks arguments. (The same leak after time, timeout, env and the other old wrappers
# is closed by the overlapping scan in section 15, GH #245.) --- #
for _c in \
  'eval "$(ssh-agent -s)" && git stash && git status' \
  'eval true; git stash; git status' \
  'rtk ls && git stash && git status' \
  'builtin cd /tmp && git clean -n && git status' \
  'rtk run -n||timeout 5 bash -c "git stash"; git status' \
  'rtk -v||git stash' \
  'rtk run -x&&git stash' \
  'rtk proxy -v;git stash' \
  'eval true; bash -c "git stash"; bash -c "git status"' \
  'builtin cd x && sh -c "git stash" && sh -c "git status"' \
  'rtk ls && eval "git stash" && eval "git status"' \
  $'eval "$(direnv export bash)"\ngit stash\ngit status' \
  $'rtk git status\ngit stash\ngit log -1' \
  'nohup >/dev/null 2>&1 git stash' \
  'env FOO=1 2>&1 git stash' \
  'env FOO=1 &>/dev/null git stash' \
  'env A=$(printf x) git stash' \
  'env A=\;x git stash' \
  'sudo -u $(id -un) git stash' \
  'env A=$(a b) FOO=1 git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "later statement still checked behind a wrapper: $_c" "$ok"
done
for _c in \
  'eval "$(ssh-agent -s)"; echo git stash done' \
  'time ls; git status; git log' \
  'eval true && git status && git log' \
  'env FOO=1 make; git stash list; git status' \
  'nohup >/dev/null 2>&1 git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "walk-boundary control allowed for a subagent: $_c" "$ok"
done

# --- (15) GH #245: after an old wrapper (time, timeout, env, sudo, ...) the greedy argument walk
# crosses `;` / `&&` / `||` / `|` / newline to the LAST `git` (or shell word), and finditer resumed
# after that match, so an earlier statement was never checked. Anchors are now found by an
# overlapping scan, so every separator inside a walked span gets its own attempt. --- #
for _c in \
  'time ls; git stash; git status' \
  'timeout 5 ls && git reset --hard && git status' \
  'env FOO=1 make || git clean -fd; git status' \
  'sudo ls | git stash; git log -1' \
  'nice make; git -C /r stash; git status' \
  $'time ls\ngit stash\ngit status' \
  'time ls; bash -c "git stash"; bash -c "git status"' \
  'env A=1 ls && sh -c "git reset --hard" && sh -c "git log"' \
  'time ls; eval "git stash"; eval "git status"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "earlier statement behind an old wrapper still checked: $_c" "$ok"
done
for _c in \
  'time ls; git status; git log' \
  'timeout 5 make && git diff && git status' \
  'time ls; bash -c "git status"; bash -c "git log"' \
  'env FOO=1 make; git stash list; git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "old-wrapper multi-statement control allowed: $_c" "$ok"
done

# --- (16) GH #246: every anchor scan is quadratic on padded input, and a hook past its 8 s timeout
# allows. Padding in front of a real `git stash` (5000 x `env ; `, 30 KB) walked around the deny.
# A shared work budget now denies a command too dense to scan, fast, and never scans it. --- #
_pad() { python3 -c 'import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }
_t0=$(date +%s)
_c="git $(_pad '-c a ' 20000); git stash"  # the flag walk re-sliced the tail per flag (4.6 s at 1.25 MB; a Linux argv arg caps this row at 128 KB)
rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "long git flag run still reaches the deny (${#_c} bytes)" "$ok"
_PAD_ENV=$(_pad 'env ; ' 5000; printf x); _PAD_ENV=${_PAD_ENV%x}  # keep the trailing blank $(...) would strip
_PAD_NL=$(_pad $'\n' 6000; printf x); _PAD_NL=${_PAD_NL%x}  # $(...) strips trailing newlines
for _c in \
  "${_PAD_ENV}time ls; git stash; git status" \
  "${_PAD_ENV}git status" \
  "${_PAD_NL}git status" \
  "bash -c \"${_PAD_ENV}git status\"" \
  "eval '${_PAD_NL}git status'" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "padded command denied, not timed out into allow (${#_c} bytes): ${_c:0:30}" "$ok"
done
_out=$(payload "${_PAD_ENV}git status" fork | bash "$GATE" 2>&1 >/dev/null)
case "$_out" in *"too long or too dense"*) ok=0 ;; *) ok=1 ;; esac
check "over-budget deny names the reason and the way out" "$ok"
_el=$(( $(date +%s) - _t0 ))
ok=1; [ "$_el" -lt 8 ] && ok=0
check "all padded shapes decided well inside the 8 s hook timeout (${_el}s for the section)" "$ok"
for _c in \
  "echo $(_pad x 20000)" \
  "$(_pad $'echo hello world\n' 400)git status" \
  "$(_pad 'ls -la; ' 200)git log -1" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "long but ordinary command still allowed (${#_c} bytes): ${_c:0:30}" "$ok"
done

# GH #248: a wrapped FIRST statement (the greedy walk lands on the last git) and a brace group.
for _c in \
  'time git stash; git status' \
  'env A=1 git reset --hard; git status' \
  'timeout 5 git clean -fd && git status' \
  'xargs git stash; git status' \
  '{ git stash; }' \
  'true; { git reset --hard; }' \
  '{ git clean -fd; } 2>&1' \
  'bash -c "{ git stash; }"' \
  'bash -c "time git stash; git status"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #248 denied: $_c" "$ok"
done
for _c in \
  'time git status; git log -1' \
  '{ git status; }' \
  'echo {a,b} git stash' \
  'git commit -m "{ git stash; }"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #248 control still allowed: $_c" "$ok"
done

# --- (17) Deep-audit 5: the chain prefix (eval/builtin/command/exec/rtk) after a wrapper walk re-reads
# the rest of a chain run from every walk position, so a long run costs run x run per command start,
# which the separator x length charge never saw: `true; ` + `command ` x 8000 before a real
# `git stash` ran 9 s with one `;`, and a timed-out hook allows. Each row must be DECIDED inside 8 s:
# sgg_rc waits forever, so a late deny would read as a pass. --- #
# A load spike (peer gauntlets, GH #158) can push a fast row past 8 s once, and a sustained one
# (load average 5-8 with peer sessions live) twice; a real quadratic scan takes 9 s or more every
# time, so a row only fails when all three tries time out.
sgg_rc8() {
  local rc _try; rc=124
  for _try in 1 2 3; do rc=$(_sgg_rc8_once "$1"); [ "$rc" != "124" ] && break; done
  echo "$rc"
}
_sgg_rc8_once() {
  payload "$1" fork | python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(["bash", sys.argv[1]], stdin=sys.stdin, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
try:
    print(p.wait(timeout=8))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print(124)
' "$GATE"
}
for _c in \
  "true; $(_pad 'command ' 8000)git stash; git status" \
  "time git stash; time $(_pad 'rtk -a ' 8000)ls" \
  "time git stash; git status; $(_pad 'time ; ' 50)$(_pad 'command ' 1000)ls" \
  "bash -c 'true; $(_pad 'command ' 8000)git stash; git status'" \
  "sudo $(_pad 'git -C ' 10000)x; time git stash; git status" \
  "sudo -u git $(_pad 'git ' 20000)stash; git status" \
  "sudo -u git $(_pad 'git -u ' 10000)env git stash; git status" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "padded command denied inside 8 s, not timed out into allow (rc $rc, ${#_c} bytes): ${_c:0:30}" "$ok"
done
# GH #276 deep-audit: the scan after a wrapper-argument git re-sliced the tail per hit (quadratic
# copying, 8 s at ~2 MB). A payload that size never fits an argv, so it is built and piped here.
_rc=$(python3 -c '
import json, signal, subprocess, sys, os
c = "sudo -u git env " + "-u git " * 330000 + "git stash; git status"
d = json.dumps({"tool_name": "Bash", "tool_input": {"command": c}, "agent_id": "a", "agent_type": "general-purpose"})
for _ in range(2):  # a load spike can time one run out; a real slowdown times out both (GH #158)
    p = subprocess.Popen(["bash", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        p.communicate(d.encode(), timeout=8)
        print(p.returncode)
        break
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
else:
    print(124)
' "$GATE")
ok=1; [ "$_rc" = "2" ] && ok=0
check "2 MB run of wrapper-argument git words denied inside 8 s, not timed out into allow (rc $_rc)" "$ok"
# GH #327: the second-parse body of an eval copies its substitution spans, which the raw scan already
# read. Body strings are now checked once: a late target behind 2 million backticks took 8.3 s on develop
# (a timed-out hook allows) and 8.9 s with the second-parse body and no dedupe; 3 s now.
# Also time a 2 MB double-quoted body and a 40 KB eval body whose target only the second parse finds.
for _shape in bt dq evdq; do
_rc=$(python3 -c '
import json, signal, subprocess, sys, os
bs, dq, bt = chr(92), chr(34), chr(96)
c = {"bt": "eval " + bt * 2000000 + "; echo " + dq + "$(git stash)" + dq,
     "dq": "bash -c " + dq + "a " * 1000000 + "; g" + bs * 2 + "it stash" + dq,
     "evdq": "eval " + dq + "a; " * 13000 + "g" + bs * 2 + "it stash" + dq}[sys.argv[2]]
d = json.dumps({"tool_name": "Bash", "tool_input": {"command": c}, "agent_id": "a", "agent_type": "general-purpose"})
for _ in range(2):  # a load spike can time one run out; a real slowdown times out both (GH #158)
    p = subprocess.Popen(["bash", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        p.communicate(d.encode(), timeout=8)
        print(p.returncode)
        break
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
else:
    print(124)
' "$GATE" "$_shape")
ok=1; [ "$_rc" = "2" ] && ok=0
check "GH #327: second-parse worst case ($_shape) denied inside 8 s, not timed out into allow (rc $_rc)" "$ok"
done
# The last row guards a dropped fix: a lazy target that looked ahead for the denied subcommand
# re-read a `git -C` run from every `git` (11 s at 70 KB).
# GH #276: a wrapper argument spelled git stopped the lazy target; the guard now re-checks from a
# git word that directly follows the anchored one (one forward walk, so the row above stays fast).
for _c in \
  'sudo -u git git stash; git status' \
  'xargs -I git git stash; git status' \
  'sudo -u git git -C /r reset --hard; git log -1' \
  'sudo -g git -u root git stash; git status' \
  'sudo -u git env git stash; git status' \
  'sudo -u git sudo git stash; git status' \
  'sudo -u git git -C /r -u root git stash; git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "wrapper argument spelled git no longer hides a denied statement: $_c" "$ok"
done
for _c in \
  'command -v git && git status' \
  'eval "$(ssh-agent -s)"; git status' \
  'rtk proxy git status' \
  'sudo -u git git status; git log -1' \
  'sudo -u git git stash list; git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "chain and wrapper-argument control still allowed: $_c" "$ok"
done

# GH #274: git inside a double-quoted $(...) or backticks is a real command; single-quoted text is not.
for _c in \
  'echo "$(git clean -fd)"' \
  'echo `sudo -u git git clean -fd`' \
  'echo "a `git stash` b"' \
  'echo "x $(echo "$(git reset --hard)")"' \
  'echo "$(true; git stash)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "git in quoted substitution denied: $_c" "$ok"
done
for _c in \
  "echo '\$(git clean -fd)'" \
  'echo "$(git status)"' \
  'echo "git clean is denied"' \
  'echo "\$(git clean -fd)"' \
  'git commit -m "$(cat <<'"'EOF'"'
fix

git stash was the cause
EOF
)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "literal or safe substitution allowed: ${_c:0:40}" "$ok"
done
for _c in \
  'echo "`echo \`git stash\``"' \
  'echo "`echo \`echo \\\`git stash\\\`\``"' \
  'echo "$(case x in x) git stash;; esac)"' \
  'echo "$(case x in (x) git clean -fd;; esac)"' \
  'echo "$(if true; then case x in x) git reset --hard;; esac; fi)"' \
  'echo "$(echo x # )
git stash)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #274 shapes the first scanner missed denied: ${_c:0:40}" "$ok"
done
for _c in \
  'echo "$(echo case) git stash is bad"' \
  'echo "$(echo hi # git stash
)"' \
  'echo $(date) git stash is dangerous' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "prose around a substitution allowed: ${_c:0:40}" "$ok"
done
# Second fuzz round (real-shell differential): `${y:-)}`, shell bodies, backslash escapes inside
# backticks, a backtick inside quotes inside backticks (zsh nests it), heredoc shapes.
_nl() { local IFS=$'\n'; echo "$*"; }
for _c in \
  'echo "$(echo ${y:-)}; git stash)"' \
  "bash -c 'echo \"\$(git stash)\"'" \
  'echo `"\$(git clean -fd)"`' \
  'echo `"`git stash`"`' \
  "$(_nl 'echo "$(cat <<A <<B' x A '$(git stash)' B ')"')" \
  "$(_nl 'echo "$(cat <<EOF' "it's \`git stash\`" EOF ')"')" \
  "$(_nl 'echo "$(echo "<<A"' 'git stash' A ')"')" \
  "$(_nl 'git commit -m "$(cat <<EOF' 'an unquoted heredoc runs `git stash` here' EOF ')"')" \
  "$(_nl 'echo "$(cat <<EOF-1' data EOF-1 'git stash' EOF ')"')" \
  "$(_nl 'echo "$(echo $((1<<EOF));' 'git stash' EOF ')"')" \
  "$(_nl 'echo "$(cat <<E"O"F' 'git stash' EOF ')"')" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "second-round shape denied: ${_c:0:50}" "$ok"
done
for _c in \
  "$(_nl 'git commit -m "$(cat <<'"'EOF'" 'fix: handle `git stash` and $(git clean -fd) in prose' '' EOF ')"')" \
  "$(_nl 'echo "$(cat <<A <<B' 'git stash is data' A 'git reset is data' B ')"')" \
  "$(_nl 'echo "$(cat <<'"'E-1'" 'git stash is data' E-1 ')"')" \
  "$(_nl 'echo "$(cat <<-EOF' '	git stash is data' '	EOF' ')"')" \
  'echo "$(echo $((1<<2)); git status)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "heredoc prose and safe shapes allowed: ${_c:0:50}" "$ok"
done
# Real-shell corpus (deep-audit 2026-10-01): each case was run through sh, bash and zsh against a shim
# git. DENY = some shell ran stash/reset/clean and the gate says so by name; DENY-HEREDOC = the same
# but the gate refuses it as an unreadable heredoc (a different deny, so it cannot hide a missing git
# check); ALLOW = no shell ran one. Blocks split on a %% line. A corpus that replays fewer cases than
# the fixture holds, or fails to load, fails the run.
# GH #327: the second corpus holds second-parse shapes (eval, a double-quoted `sh -c` body), checked
# against sh, bash 3.2, bash 5, dash, zsh and ksh the same way.
for _corpus_min in substitution:25 reparse:20; do
_corpus="$ROOT/tests/hooks/fixtures/subagent-git-guard-${_corpus_min%:*}-cases.txt"
_corpus_rs="$_JOURNAL_TMP/corpus.rs"
python3 -c '
import sys
for b in open(sys.argv[1]).read().split("\n%%\n"):
    if b.strip(): sys.stdout.write(b.rstrip("\n") + chr(30))
' "$_corpus" > "$_corpus_rs"; _prod=$?
_want_n=$(/usr/bin/grep -cE '^(DENY|DENY-HEREDOC|ALLOW) ' "$_corpus"); _got_n=0
while IFS= read -r -d $'\x1e' _blk; do
  _head="${_blk%%$'\n'*}"; _c="${_blk#*$'\n'}"; _got_n=$((_got_n + 1))
  _err=$(payload "$_c" fork | bash "$GATE" 2>&1 >/dev/null); rc=$?
  ok=1
  case "$_head" in
    DENY-HEREDOC\ *) [ "$rc" = 2 ] && [[ "$_err" == *"cannot read"* ]] && ok=0 ;;
    DENY\ *) [ "$rc" = 2 ] && [[ "$_err" == *"may not run"* ]] && ok=0 ;;
    *) [ "$rc" = 0 ] && ok=0 ;;
  esac
  check "corpus ${_head} (rc $rc)" "$ok"
done < "$_corpus_rs"
ok=1; [ "$_prod" = 0 ] && [ "$_want_n" -ge "${_corpus_min#*:}" ] && [ "$_got_n" = "$_want_n" ] && ok=0
check "${_corpus_min%:*} corpus replayed every case (loaded $_got_n of $_want_n, loader exit $_prod)" "$ok"
done
# A big document written through a quoted heredoc must not be refused as too costly (replay of real
# transcripts: two 12-17 KB writes were denied by the scans' work budget, which develop allowed).
_c=$(python3 -c '
lines = ["cat > /tmp/doc.md <<'"'"'DOCEOF'"'"'", "# Diagrams"]
lines += ["  node%d(step %d) --> node%d : label text for this step of the flow" % (i, i, i + 1) for i in range(190)]
lines += ["DOCEOF"]
print("\n".join(lines))
')
rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && [ "${#_c}" -gt 12000 ] && ok=0
check "large quoted-heredoc document is allowed (rc $rc, ${#_c} bytes)" "$ok"
_c='echo "$(cat <<EOF
x
$(git stash)
EOF
)"'
rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "substitution nested in a heredoc body still denied" "$ok"
# GH #274: git inside a double-quoted $(...) or inside backticks ran unchecked (the quote mask hid it).
for _c in \
  'echo "$(git clean -fd)"' \
  'echo `sudo -u git git clean -fd`' \
  'echo "a $(true; git stash) b"' \
  'echo "$(echo "$(git reset --hard)")"' \
  'echo "x `git stash`"' \
  'echo "$(bash -c "git stash")"' \
  'echo '"'"'\'"'"'"$(git clean -fd)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "git inside a quoted substitution or backticks denied: $_c" "$ok"
done
for _c in \
  'echo "$(git status)"' \
  'echo "$(git stash list)"' \
  "echo '\$(git stash)'" \
  "echo '\`git stash\`'" \
  'echo "\$(git stash)"' \
  'echo "$(echo hi) git stash"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "substitution scan has no false deny: $_c" "$ok"
done

# --- (18) GH #275: a huge flag token after a shell word backtracked quadratically inside the shell-body
# anchor's `-\w*c\w*`, a cost no charge covers (60 KB ran past 20 s). Each row must be decided in 8 s. --- #
for _c in \
  "bash -$(_pad c 60000)= x; time git stash; git status" \
  "bash -$(_pad c 60000)" ; do
  rc=$(sgg_rc8 "$_c"); ok=1
  # the bare flag token carries no git command: exactly rc 0 passes (an over-deny, rc 2, fails); the others exactly rc 2
  case "$_c" in "bash -"*cc) [ "$rc" = "0" ] && ok=0 ;; *) [ "$rc" = "2" ] && ok=0 ;; esac
  check "huge flag token decided inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:20}" "$ok"
done
for _c in 'bash -c "git status"' 'bash -xc "git status"' 'bash -x -ec "git status"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #275 control still allowed: $_c" "$ok"
done
for _c in 'bash -c "git stash"' 'bash -xc "git stash"' 'bash -x -ec "git reset --hard"' 'bash -cx "git stash"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #275 control still denied: $_c" "$ok"
done

# --- (19) GH #273: a chain word before a wrapper (eval/rtk, then sudo/time/env/nice) still anchors git. --- #
for _c in \
  'eval sudo git stash' \
  'eval time git stash' \
  'eval env A=1 git clean -fd' \
  'eval nice -n 5 git stash' \
  'rtk proxy sudo git stash' \
  'rtk proxy time git stash' \
  'eval sudo eval time git reset --hard' \
  'true; eval sudo git stash; git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "chain word before a wrapper denied: $_c" "$ok"
done
for _c in \
  'eval sudo git status' \
  'rtk proxy time git stash list' \
  'eval env A=1 git log -1' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "chain word before a wrapper, read-only git allowed: $_c" "$ok"
done
for _c in \
  "true; $(_pad 'eval sudo ' 4000)git stash; git status" \
  "$(_pad "eval sudo $(_pad 's ' 300);" 40)git stash; git status" \
  "$(_pad 'command ' 1000)eval \"git stash\"" \
  "$(_pad 'command ' 700)eval \"git stash\"" \
  "true; $(_pad 'exec ' 700)eval \"git stash\"" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "interleaved padded command decided inside 8 s as deny (rc $rc, ${#_c} bytes): ${_c:0:30}" "$ok"
done
# The slowest shape is the allowed one: many `eval sudo` starts, each walking to the end, no target.
# Allowed or budget-refused both finish; only a timeout (rc 124) is the failure.
_c="$(_pad "eval sudo $(_pad 's ' 1000);" 70)ls"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
check "many-start allow shape finishes inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:30}" "$ok"
# Bodies reached only by the greedy passes: a lead word that took exec or command lost the anchor
# develop gave these (deep-audit whole-picture pass).
for _c in \
  "time eval x bash -c 'rtk exec git stash; git status'" \
  "time eval x bash -c 'eval command git stash; git status'" \
  "sudo eval x eval 'builtin exec git reset --hard; git status'" \
  "bash -c 'rtk exec git stash; git status'" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "chain-word body still denied, as on develop: $_c" "$ok"
done

# --- (20) GH #273 follow-ups: eval takes assignments (it joins its args into a command line, so
# `eval A=1 env git stash` runs git), and doas is a wrapper. --- #
for _c in \
  'eval A=1 env git stash' \
  'eval A=1 git stash' \
  'eval -- A=1 B=2 git reset --hard' \
  'true; eval A=1 B=2 sudo git clean -fd; git status' \
  "bash -c 'eval A=1 env git stash; git status'" \
  'eval doas git stash' \
  'doas -u x git clean -fd' \
  'rtk proxy doas git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "eval assignment / doas wrapper denied: $_c" "$ok"
done
for _c in \
  'eval A=1 git status' \
  'eval A=1 sudo git stash list' \
  'doas git status' \
  'doas -u x git stash show' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "eval assignment / doas wrapper, read-only git allowed: $_c" "$ok"
done
_c="eval $(_pad 'A=1 ' 6000)git status"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
check "long eval assignment run finishes inside 8 s (rc $rc, ${#_c} bytes)" "$ok"

# --- (21) GH #285: a redirection before the command word hid `git` from the anchor. --- #
for _c in \
  '</dev/null git stash' \
  '< /dev/null git stash' \
  '>/dev/null git stash' \
  '2>&1 git reset --hard' \
  '&>/dev/null git clean -fd' \
  '2>/dev/null </dev/null git stash' \
  'FOO=1 </dev/null git stash' \
  '</dev/null FOO=1 git stash' \
  'true; </dev/null git stash' \
  '</dev/null sudo git stash' \
  '</dev/null env git stash' \
  '<<<x git stash' \
  '<<EOF git stash
EOF' \
  'x=$(<<EOF git stash
EOF
)' \
  'echo $(</dev/null git stash)' \
  '</dev/null /usr/bin/git stash' \
  '</dev/null git -C /r stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #285 redirect before git denied: ${_c%%$'\n'*}" "$ok"
done
for _c in \
  '</dev/null git status' \
  '2>&1 git log' \
  '>/dev/null git stash list' \
  '</dev/null git diff' \
  'echo a >f; git status' \
  'cat </dev/null' \
  'echo "</dev/null git stash"' \
  'git commit -m "x </dev/null git stash"' \
  'ls 2>&1 | grep git' \
  'x=$(</dev/null git log)' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #285 control still allowed: $_c" "$ok"
done

# GH #286: backslash-newline joins lines, so a "#" after it is mid-word and
# the rest of the line runs (verified sh/bash/zsh with a fake git function).
for _c in \
  $'echo x\\\n#y; git stash' \
  $'echo x\\\n#y\\\n#z; git stash' \
  $'echo "a"\\\n#y; git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #286 denied (hash after line continuation is not a comment): ${_c//$'\n'/<nl>}" "$ok"
done
for _c in \
  $'echo x\n# y; git stash' \
  $'echo x \\\n#y; git stash' \
  $'echo x \\\\\n#y; git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #286 control allowed (real comment): ${_c//$'\n'/<nl>}" "$ok"
done

# GH #306: the shell deletes a backslash-newline. After a word char it was masked as QQ glued to
# that word, so the next word hid even when a blank followed, and a mid-word split hid git/stash.
# Each row runs git stash/reset/clean in bash 3.2, bash 5, dash and zsh (logging git stub).
for _c in \
  $'git\\\n stash' \
  $'g\\\nit stash' \
  $'git s\\\ntash' \
  $'git re\\\nset' \
  $'git clean\\\n -fd' \
  $'env\\\n git stash' \
  $'time\\\n git stash' \
  $'sudo\\\n git stash' \
  $'command\\\n git stash' \
  $'eval\\\n git stash' \
  $'{\\\n git stash; }' \
  $'if true; then\\\n git stash; fi' \
  $'for i in 1; do\\\n git stash; done' \
  $'git stash\\\n' \
  $'g\\\ni\\\nt st\\\nash' \
  $'\'\'\\\ngit stash' \
  $'bash -c "git \\\nstash"' \
  $'bash -c \'g\\\nit stash\'' \
  $'eval \'g\\\nit stash\'' \
  $'eval "git\\\n stash"' \
  $'bash -c\\\n \'git stash\'' \
  $'bash -c \\\n"git reset"' \
  $'e\\\nval \\\n\'git stash\'' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #306 denied (line continuation hid a word): ${_c//$'\n'/<nl>}" "$ok"
done
# Controls: a real glue (git + continuation + stash is the one word gitstash) and git as an argument.
for _c in \
  $'git\\\nstash' \
  $'echo git\\\n stash' \
  $'echo g\\\nit stash' \
  $'git st\\\natus' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #306 control allowed: ${_c//$'\n'/<nl>}" "$ok"
done

# --- (22) GH #307: chain word (eval/builtin/rtk), then command|exec, then a wrapper, then git. --- #
# The lead-chain lookahead excluded command/exec, so the run never started and the walk began at the chain word.
_w22=(env sudo time nohup nice setsid xargs doas)
for _ch in eval builtin rtk; do
  for _ce in command exec; do
    for _w in "${_w22[@]}"; do
      _c="$_ch $_ce $_w git stash"
      rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
      check "GH #307 chain+$_ce+wrapper denied: $_c" "$ok"
    done
  done
done
for _c in \
  'eval command -p env git reset --hard' \
  'eval command -- sudo git clean -fd' \
  'eval command exec env git stash' \
  'eval A=1 command env git stash' \
  'rtk proxy command time git stash' \
  'true; eval command env git stash; git status' \
  "bash -c 'eval exec sudo git stash; git status'" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #307 variant denied: $_c" "$ok"
done
for _c in \
  'eval command ls' \
  'eval command env ls' \
  'eval exec sudo ls' \
  'builtin command time git status' \
  'rtk exec env git stash list' \
  'eval command env git log -1' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #307 control allowed: $_c" "$ok"
done
for _c in \
  "true; $(_pad 'eval command env ' 4000)git stash; git status" \
  "$(_pad "eval command sudo $(_pad 's ' 300);" 40)git stash; git status" \
  "eval $(_pad 'command ' 5000)env git stash" \
  "$(_pad 'eval command ' 3000)env git stash" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #307 padded command decided inside 8 s as deny (rc $rc, ${#_c} bytes): ${_c:0:30}" "$ok"
done
for _c in \
  "$(_pad "eval command sudo $(_pad 's ' 1000);" 70)ls" \
  "$(_pad 'eval command ' 6000)ls" \
  "eval $(_pad 'command ' 8000)ls" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
  check "GH #307 allow shape finishes inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:30}" "$ok"
done

# GH #469 follow-up: the work budget does not track wall time (an allowed shape took 7.1 s at 40M, a
# refused one 7.4 s), so a length cap decides before any scan. It bounds the pre-mask linear cost (the
# 20 MB row below), not the time of a shape under the cap (see repo-gotchas, GH #469).
_big="echo $(_pad 'a' 16100)"
rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_big"); ok=1; [ "$rc" = "2" ] && ok=0
check "over-length command (${#_big} chars) is denied before any scan (rc $rc)" "$ok"
_ok="echo $(_pad 'a' 15900)"
rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_ok"); ok=1; [ "$rc" = "0" ] && ok=0
check "a ${#_ok}-char benign command is still allowed (rc $rc)" "$ok"
# The cap counts characters, not bytes: 8000 emoji are 32 KB of UTF-8 but 8000 characters of scan work.
_ok="echo $(_pad '😀' 8000)"
rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_ok"); ok=1; [ "$rc" = "0" ] && ok=0
check "8000 emoji (32 KB of UTF-8, 8000 characters) is under a character cap (rc $rc)" "$ok"
# The cap decides before the quote mask runs: a 20 MB command of quoted words took the mask alone about 9 s.
# The payload is built inside python, since a 20 MB argv would fail and the gate would see no command.
rc=$(unset MH_SGG_MAX_CMD_CHARS; python3 -c '
import json, os, signal, subprocess, sys
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "\"g\" " * 5000000 + "; git stash"},
                      "agent_id": "fork", "agent_type": "general-purpose"}).encode()
p = subprocess.Popen(["bash", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
try:
    p.communicate(payload, timeout=8)
    print(p.returncode)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print(124)
' "$GATE")
ok=1; [ "$rc" = "2" ] && ok=0
check "a 20 MB command is denied inside 8 s, before the quote mask (rc $rc)" "$ok"
# GH #469: no length decides time (see above), so the gate also arms a wall-clock deadline of its own
# (default 5 s, under the 8 s hook timeout; a timed-out hook allows) and denies when it fires. The row
# below is a padded eval-sudo shape that took 6.5 s with no deadline; with a 1 s deadline it must be
# denied within 4 s, with the deadline's own message (the work budget's message would say "too dense").
rc_msg=$(MH_SGG_DEADLINE_SECS=1 python3 -c '
import json, subprocess, sys, time
cmd = ("eval sudo " + "s " * 24 + ";") * 270 + "git stash $" + chr(34) + "show" + chr(34)
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd},
                      "agent_id": "fork", "agent_type": "general-purpose"}).encode()
t = time.time()
p = subprocess.run(["bash", sys.argv[1]], input=payload, capture_output=True, timeout=30)
print(p.returncode, round(time.time() - t, 1), "time limit" in p.stderr.decode())
' "$GATE")
set -- $rc_msg; ok=1; [ "$1" = "2" ] && [ "${2%.*}" -lt 4 ] && [ "$3" = "True" ] && ok=0
check "a slow padded shape is denied by the deadline within 4 s, with its own message (rc/secs/message: $rc_msg)" "$ok"
# A zero, negative or non-numeric deadline must neither disarm the deadline nor lock everything out: it
# falls back to the 5 s default and says so on stderr (the diagnostic is what shows the fallback ran;
# an `echo hi` allow alone would pass with the timer disarmed). A valid value prints nothing.
_dl_probe() { # $1 MH_SGG_DEADLINE_SECS value, $2 command -> "<rc> <fallback diagnostic seen?>"
  MH_SGG_DEADLINE_SECS=$1 python3 -c '
import json, subprocess, sys
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]},
                      "agent_id": "fork", "agent_type": "general-purpose"}).encode()
p = subprocess.run(["bash", sys.argv[1]], input=payload, capture_output=True, timeout=30)
print(p.returncode, "using 5 s" in p.stderr.decode())
' "$GATE" "$2"
}
for _dv in 0 -1 abc nan; do
  _pr=$(_dl_probe "$_dv" "echo hi"); ok=1; [ "$_pr" = "0 True" ] && ok=0
  check "MH_SGG_DEADLINE_SECS=$_dv falls back to the 5 s default with a diagnostic, echo hi allowed ($_pr)" "$ok"
done
_pr=$(_dl_probe 3 "echo hi"); ok=1; [ "$_pr" = "0 False" ] && ok=0
check "a valid MH_SGG_DEADLINE_SECS=3 prints no fallback diagnostic ($_pr)" "$ok"
# An override over the 7 s clamp (past the 8 s hook timeout) is clamped to 7 and says so, so the clamp is
# observable: without it, a 100 s deadline would let a slow scan run into the timeout (= allow).
for _dv in 100 inf; do
  _pr=$(MH_SGG_DEADLINE_SECS=$_dv python3 -c '
import json, subprocess, sys
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "echo hi"},
                      "agent_id": "fork", "agent_type": "general-purpose"}).encode()
p = subprocess.run(["bash", sys.argv[1]], input=payload, capture_output=True, timeout=30)
print(p.returncode, "clamped to 7 s" in p.stderr.decode())
' "$GATE"); ok=1; [ "$_pr" = "0 True" ] && ok=0
  check "MH_SGG_DEADLINE_SECS=$_dv is clamped to 7 s with a diagnostic, echo hi allowed ($_pr)" "$ok"
done
# A deny must survive an unwritable stderr: a print that raises exits 120, which is not a deny, so the
# command would run. Each row closes the read end of the stderr pipe before the gate writes its deny.
_closed_stderr_rc() { # $1 command, $2 extra env assignment (NAME=value) or empty -> exit code
  python3 -c '
import json, os, subprocess, sys
r, w = os.pipe()
os.close(r)
env = dict(os.environ)
if sys.argv[3]:
    k, v = sys.argv[3].split("=", 1)
    env[k] = v
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]},
                      "agent_id": "fork", "agent_type": "general-purpose"}).encode()
p = subprocess.run(["bash", sys.argv[1]], input=payload, stdout=subprocess.DEVNULL, stderr=w, timeout=30, env=env)
print(p.returncode)
' "$GATE" "$1" "$2"
}
_big="echo $(_pad 'a' 16100)"
for _case in "git stash|" "$_big|MH_SGG_MAX_CMD_CHARS=16000" "git stash|MH_SGG_DEADLINE_SECS=abc"; do
  rc=$(_closed_stderr_rc "${_case%%|*}" "${_case#*|}"); ok=1; [ "$rc" = "2" ] && ok=0
  check "deny exits 2 with stderr unwritable: ${_case:0:40} (rc $rc)" "$ok"
done
# A value too large for setitimer (or past the 8 s hook timeout) must still arm a deadline, never crash the
# gate: a crash exits 1, which is not a deny, so the command would run.
for _dv in inf 1e300 100; do
  _pr=$(_dl_probe "$_dv" "git stash"); ok=1; [ "${_pr%% *}" = "2" ] && ok=0
  check "MH_SGG_DEADLINE_SECS=$_dv still denies git stash instead of crashing the gate ($_pr)" "$ok"
done
# A zero or negative override must not lock every subagent Bash command out: it falls back to the cap.
for _ov in 0 -1 abc; do
  rc=$(MH_SGG_MAX_CMD_CHARS=$_ov sgg_rc8 "echo hi"); ok=1; [ "$rc" = "0" ] && ok=0
  check "MH_SGG_MAX_CMD_CHARS=$_ov keeps the default cap, echo hi allowed (rc $rc)" "$ok"
done

# --- (23) GH #318: zsh runs a brace group with no blank after `{` (`{git stash;}`); bash, dash and
# ksh read `{git` as a word. The Bash tool runs zsh here, so a glued `{` is a command start too (any
# deny wins). Each deny row runs git stash/reset/clean in zsh (logging git stub); the controls run none.
for _c in \
  '{git stash;}' \
  '{git stash; }' \
  '{git reset --hard;}' \
  '{git clean -fd;}' \
  '{git stash}' \
  $'{git stash\n}' \
  'true; {git stash;}' \
  'true&&{git stash;}' \
  '{ {git stash;}; }' \
  '{{git stash;};}' \
  'if true; then {git stash;}; fi' \
  '! {git stash;}' \
  '({git stash;})' \
  '{env git stash;}' \
  '{time git stash;}' \
  '{A=1 git stash;}' \
  '{git -C . stash;}' \
  '{git stash;} 2>&1' \
  'time {git stash;}' \
  '{git stash;}; git status' \
  '(){git stash;}' \
  'f(){git stash;}; f' \
  'for i in 1; {git stash;}' \
  '2>&1 {git stash;}' \
  'echo $({git stash;})' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #318 denied (zsh glued brace group): ${_c//$'\n'/<nl>}" "$ok"
done
for _c in \
  '{git status;}' \
  '{git stash list;}' \
  'echo {git,x} stash' \
  '{}git stash' \
  'x{git stash;}' \
  '${git stash;}' \
  '{true;}{git stash;}' \
  'echo {a,b} git stash' \
  'git commit -m "fix {git stash;}"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #318 control allowed: $_c" "$ok"
done
# Every glued `{` is now a command start; a long run of them must still be decided inside 8 s.
_c="$(_pad '{' 3000)git stash;}"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #318 padded glued braces decided inside 8 s as deny (rc $rc, ${#_c} bytes)" "$ok"
_c="$(_pad '{' 3000)ls"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
check "GH #318 padded glued braces allow shape finishes inside 8 s (rc $rc, ${#_c} bytes)" "$ok"

# --- (24) GH #317: a shell drops a backslash before an ordinary character, so an escaped letter in
# git, its subcommand, a flag or a wrapper/shell word still runs it. Each deny row runs git
# stash/reset/clean in sh, bash 3.2, bash 5, dash, zsh and ksh (logging git stub; the last row in zsh
# only); the controls run none (an even backslash run is a literal backslash).
for _c in \
  'g\it stash' \
  'gi\t stash' \
  '\g\i\t stash' \
  'git st\ash' \
  'git \stash' \
  'git \reset --hard' \
  'git cl\ean -fd' \
  'git res\et' \
  '\git \stash' \
  'git -\C . stash' \
  'git \-C . stash' \
  'e\nv git stash' \
  '\env git stash' \
  'ti\me git stash' \
  's\udo git stash' \
  'comm\and git stash' \
  'ev\al git stash' \
  "ev\\al 'git stash'" \
  "ba\\sh -c 'git stash'" \
  "bash -\\c 'git stash'" \
  "bash -c 'g\\it stash'" \
  'bash -c "g\it stash"' \
  'echo $(g\it stash)' \
  'echo "$(git st\ash)"' \
  "ba\\sh -c 'echo \"\$(git stash)\"'" \
  'true; g\it reset --hard' \
  '{ g\it stash; }' \
  '{g\it stash;}' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #317 denied (escaped letter): $_c" "$ok"
done
for _c in \
  'g\\it stash' \
  'g\\\it stash' \
  'g\\\\it stash' \
  'git\ stash' \
  'echo g\it stash' \
  'git \stash list' \
  'git stash l\ist' \
  'A\=1 git stash' \
  '\{git stash;}' \
  'true; \>f git stash' \
  $'echo "$(cat <<\\EOF\nhello\nEOF\n)"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #317 control allowed: ${_c//$'\n'/<nl>}" "$ok"
done

# --- (25) GH #320: a wrapper or rtk written as a path (`/usr/bin/env git stash`) runs the same
# program, so it is the same wrapper. Each deny row runs git stash/reset/clean in sh, bash 3.2,
# bash 5, dash, zsh and ksh (logging git stub; the glued-brace row in zsh only); the controls run none.
for _c in \
  '/usr/bin/env git stash' \
  '/usr/bin/nice git reset --hard' \
  '/usr/bin/time git clean -fd' \
  '/usr/bin/command git stash' \
  '/usr/bin/nohup git stash' \
  '/opt/homebrew/bin/timeout 5 git stash' \
  '( { /usr/bin/env git -C . clean -fd; } )' \
  '{/usr/bin/env git stash;}' \
  '/usr/bin/env A=1 git stash' \
  '/usr/bin/env -u X git stash' \
  '/usr/bin/env /usr/bin/nice git stash' \
  'sudo -u root /usr/bin/env git stash' \
  '/usr/bin/env true && git stash && git status' \
  'true; /usr/bin/time git stash' \
  'eval /usr/bin/env git stash' \
  'eval /usr/bin/command /usr/bin/env git stash' \
  'eval /usr/bin/command git stash' \
  'true && eval /usr/bin/command -- git stash pop' \
  'rtk proxy /usr/bin/command -- git clean -fd' \
  '/opt/homebrew/bin/rtk proxy git stash' \
  '/opt/homebrew/bin/rtk proxy /usr/bin/env git stash' \
  'rtk proxy /usr/bin/env git stash' \
  'bash -c "/usr/bin/env git stash"' \
  'echo $(/usr/bin/env git stash)' \
  '/usr/bin/e\nv git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #320 denied (wrapper written as a path): $_c" "$ok"
done
for _c in \
  '/usr/bin/env git status' \
  '/usr/bin/env git stash list' \
  'echo /usr/bin/env git stash' \
  'ls /usr/bin/env && git status' \
  '/usr/bin/env=1 git stash' \
  '/usr/bin/envy git stash' \
  '/usr/bin/xenv git stash' \
  'git commit -m "/usr/bin/env git stash"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #320 control allowed: $_c" "$ok"
done
# The path prefix is a new regex piece (`\S*/` before every wrapper word); its worst cases must
# still be decided inside 8 s.
for _c in \
  "$(_pad '/usr/bin/env ' 3000)git stash" \
  "eval $(_pad '/usr/bin/command ' 3000)/usr/bin/env git stash" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #320 padded path wrappers decided inside 8 s as deny (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done
# A prefix that may start with `-` or hold `<`/`>` lets one token read two ways (a flag or a path
# command, a redirection or a path wrapper), and the chain loops then try every split of a run:
# with `\S*/` each of the -/command, -x/rtk and 2>/x/env rows below ran past 15 s.
for _c in \
  "$(_pad '/usr/bin/env ' 3000)ls" \
  "$(_pad ';/' 4000)env ls" \
  "x $(_pad '/' 20000)env ls" \
  "eval $(_pad '/usr/bin/command ' 3000)ls" \
  "eval command $(_pad '-/command ' 40)ls" \
  "eval rtk $(_pad '-/rtk ' 40)ls" \
  "rtk $(_pad '-x/rtk ' 40)ls" \
  "$(_pad '2>/x/env ' 3000)ls" \
  "eval $(_pad 'A=/rtk ' 3000)ls" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
  check "GH #320 padded path wrappers allow shape finishes inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done

# --- (26) GH #344: a shell removes the quotes inside a word, so a quoted or partly quoted git, wrapper
# or subcommand still runs it, but the quote mask turned the quoted letters into Q. Each deny row runs
# git stash/reset/clean in sh, bash 3.2, bash 5, dash, zsh and ksh (logging git stub; $'..' rows in all
# but dash, the glued-brace row in zsh only); the controls run none.
for _c in \
  '"git" stash' \
  "g'i't stash" \
  'g""it stash' \
  'git "stash"' \
  "git 'reset' --hard" \
  'git cl"ea"n -fd' \
  '"env" git stash' \
  '"sudo" -u x git stash' \
  '"/usr/bin/env" git stash' \
  '"git" -C . stash' \
  'git -C "." "stash"' \
  'true && "git" stash' \
  'echo $("git" stash)' \
  'echo "$("git" stash)"' \
  "bash -c '\"git\" stash'" \
  '"bash" -c "git stash"' \
  '"eval" "git stash"' \
  '{ "git" stash; }' \
  '{"git" stash;}' \
  "\$'git' stash" \
  "git \$'stash'" \
  '"g"\it stash' \
  'git "res"\et --hard' \
  "git stash \$'list'" \
  'git stash $"show"' \
  "\$'git' stash \$\"show\"" ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #344 denied (quoted word): $_c" "$ok"
done
for _c in \
  'git commit -m "fix; git reset"' \
  'git commit -m "stash"' \
  'echo "git" stash' \
  "echo 'a \"git\" stash'" \
  '"git stash"' \
  '"gitx" stash' \
  '"A=1" git stash' \
  '"git" stash list' \
  'git "stash" show' \
  "git stash 'list'" \
  'git stash"x"' \
  "printf '%s\n' \"git\" \"stash\"" \
  '# "git" stash' \
  '# "git" "stash"' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #344 control allowed: $_c" "$ok"
done
# The guard's quoted-word pattern is typed again in irrecoverable.py's spawn anchor; they must not drift.
ok=$(python3 - "$ROOT/hooks/gates" <<'PY'
import re, sys
def pat(f, name):
    m = re.search(r"^" + name + r" = re\.compile\((r\".*\")\)$", open(sys.argv[1] + "/" + f).read(), re.M)
    return m and m.group(1)
a, b = pat("subagent-git-guard.py", "_QWORD_RE"), pat("irrecoverable.py", "_SPAWN_QWORD_RE")
print(0 if a and a == b else 1)
PY
)
check "GH #344 quoted-word pattern is the same in both gates" "$ok"
# The quoted-word join is a new regex piece; its worst cases must still be decided inside 8 s.
for _c in \
  "$(_pad '"e"nv ' 3000)git stash" \
  "$(_pad '"a"' 40000) ; git stash" \
  "$(_pad "'a'" 40000)\\x; git stash" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #344 padded quoted words decided inside 8 s as deny (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done
for _c in "$(_pad '"e"nv ' 3000)ls" "$(_pad '"a" ' 4000)ls" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
  check "GH #344 padded quoted words allow shape finishes inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done

# --- (27) GH #339: a chain word, then command/exec, then rtk, then a wrapper (`eval command rtk proxy nohup
# git stash`); `exec -a NAME` in a chain (`eval A=1 exec -a x doas git stash`, `rtk proxy exec -a x git
# stash`). Each deny row runs git stash/reset/clean in sh, bash 3.2, bash 5 and zsh at least (logging
# git stub; `exec -a` is not in dash); the controls run none.
for _c in \
  'eval command rtk proxy nohup git stash' \
  'eval exec rtk proxy stdbuf -oL git reset' \
  'eval A=1 exec -a x doas git stash' \
  'builtin exec -a x timeout 5 git clean -fd' \
  'eval exec -a x env git stash' \
  'builtin command rtk proxy sudo git stash' \
  'eval command rtk proxy command rtk proxy nohup git stash' \
  'eval exec -a x git stash' \
  'builtin exec -a x git reset' \
  'eval exec -a exec env git stash' \
  'eval command rtk proxy nohup true && git stash && git status' \
  'true; eval exec -a x doas git stash' \
  'eval exec -l git stash' \
  'eval exec -la x git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #339 denied (chain word before command/exec, rtk, exec -a): $_c" "$ok"
done
for _c in \
  'eval command rtk proxy nohup git status' \
  'eval exec -a x doas git stash list' \
  'builtin exec -a git ls' \
  'echo eval command rtk proxy nohup git stash' \
  'rtk proxy exec -a git ls' \
  'eval exec -a x ls && git status' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #339 control allowed: $_c" "$ok"
done
for _c in \
  "eval $(_pad 'command rtk proxy ' 2000)nohup git stash" \
  "eval $(_pad 'exec -a x ' 3000)env git stash" \
  "builtin $(_pad 'command ' 3000)rtk proxy nohup git stash" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #339 padded chain decided inside 8 s as deny (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done
for _c in \
  "eval $(_pad 'command rtk proxy ' 2000)ls" \
  "eval $(_pad 'exec -a x ' 3000)ls" \
  "eval $(_pad 'exec -a ' 4000)ls" \
  "rtk proxy $(_pad 'exec -a x ' 3000)ls" \
  "$(_pad 'eval exec -a x nohup ; ' 1500)ls" \
  "eval exec $(_pad '-a ' 200)ls" \
  "eval exec $(_pad '-la ' 200)env ls" \
  "builtin command $(_pad '-a ' 200)env ls" ; do
  rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" != "124" ] && ok=0
  check "GH #339 padded chain allow shape finishes inside 8 s (rc $rc, ${#_c} bytes): ${_c:0:24}" "$ok"
done

# --- GH #326: the wrapper skips python3 only when it can prove python would allow
# silently (no literal agent_id, no \u escape, a plain ASCII JSON object). A python3
# stub on PATH touches a marker, so each row asserts whether python ran, not just the
# verdict. Payloads are built before PATH changes, so only the gate call can trip it.
_PYREAL="$(command -v python3)"
_STUB="$_JOURNAL_TMP/pystub"; mkdir -p "$_STUB"
printf '#!/bin/sh\n: >> "$PYSTUB_MARK"\nexec "%s" "$@"\n' "$_PYREAL" > "$_STUB/python3"
chmod +x "$_STUB/python3"
export PYSTUB_MARK="$_JOURNAL_TMP/python-ran"
fp_run() { # fp_run <payload> -> sets fp_rc, fp_err, fp_py (yes|no)
  tmp_delete "$PYSTUB_MARK"
  fp_err=$(printf '%s' "$1" | PATH="$_STUB:$PATH" bash "$GATE" 2>&1 >/dev/null); fp_rc=$?
  if [ -e "$PYSTUB_MARK" ]; then fp_py=yes; else fp_py=no; fi
}
cc_payload() { # cc_payload <command> [agent_id] [ensure_ascii 1|0]: the full shape Claude Code sends
  python3 -c '
import json, sys
d = {"session_id": "s1", "transcript_path": "/t/x.jsonl", "cwd": "/w", "permission_mode": "default",
     "hook_event_name": "PreToolUse", "tool_name": "Bash",
     "tool_input": {"command": sys.argv[1], "description": "d", "timeout": 120000}, "tool_use_id": "toolu_1"}
if sys.argv[2]:
    d["agent_id"] = sys.argv[2]
    d["agent_type"] = "general-purpose"
print(json.dumps(d, ensure_ascii=sys.argv[3] == "1", separators=(",", ":")))
' "$1" "${2:-}" "${3:-1}"
}

fp_run "$(cc_payload 'ls -la src && npm test')"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = no ] && [ -z "$fp_err" ] && ok=0
check "GH #326 main session, benign command: allowed with no python3 run (rc $fp_rc, python $fp_py)" "$ok"
fp_run "$(cc_payload 'git stash')"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = no ] && ok=0
check "GH #326 main session, git stash: allowed with no python3 run (no agent_id key)" "$ok"
fp_run "$(cc_payload 'grep -rn agent_id hooks')"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 main session, command text holds agent_id: still reaches python3 (python $fp_py)" "$ok"
fp_run "$(cc_payload 'ls' agent1)"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 subagent, benign command: reaches python3 (python $fp_py)" "$ok"
fp_run "$(cc_payload 'git stash' agent1)"
ok=1; [ "$fp_rc" -eq 2 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 subagent, git stash: reaches python3 and denies (rc $fp_rc)" "$ok"
# GH #154 shape: the key spelled with a JSON \u escape decodes to agent_id but the raw
# text never holds that substring. Built with chr(92) so no transport decodes it first.
fp_run "$(python3 -c '
import json
d = {"tool_name": "Bash", "tool_input": {"command": "git stash"}, "XKEYX": "agent-1"}
print(json.dumps(d).replace("XKEYX", "agent" + chr(92) + "u005fid"))
')"
ok=1; [ "$fp_rc" -eq 2 ] && [ "$fp_py" = yes ] && ok=0
check "GH #154/#326 escaped agent_id key (\\u005f) + git stash: reaches python3 and denies (rc $fp_rc)" "$ok"
# @ stands for the backslash (chr(92)), for the same transport reason.
for _k in 'agent@u005fid' '@u0061gent_id' 'a@u0067ent@u005F@u0069d'; do
  fp_run "$(python3 -c '
import json, sys
k = sys.argv[1].replace("@", chr(92))
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git stash"}, "XKEYX": None}).replace("XKEYX", k))
' "$_k")"
  ok=1; [ "$fp_rc" -eq 2 ] && [ "$fp_py" = yes ] && ok=0
  check "GH #154/#326 escaped key spelling $_k (@ = backslash), null value + git stash: denies (rc $fp_rc)" "$ok"
done
fp_run "$(cc_payload 'echo café')"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 any \\u escape (ensure_ascii é) reaches python3 (python $fp_py)" "$ok"
fp_run "$(cc_payload 'echo สวัสดี' '' 0)"
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 raw non-ASCII payload reaches python3 (the shape proof is ASCII-only; python $fp_py)" "$ok"
# Malformed and non-object payloads keep python3's stderr diagnostic (identical output).
for _p in '{"tool_name":"Bash","tool_input":{"command":"ls"}' '[{"tool_name":"Bash"}]' \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}x' '{"a":01}' '{"a":"x\q"}' ''; do
  fp_run "$_p"
  ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && [ -n "$fp_err" ] && ok=0
  check "GH #326 malformed/non-object payload reaches python3 and keeps its diagnostic: ${_p:0:40}" "$ok"
done
# Invalid JSON the regex must refuse: raw control bytes inside a string, a [ opening an object body.
for _p in "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"a$(printf '\t')b\"}}" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"a$(printf '\001')b\"}}" \
  '["tool_name":"Bash","tool_input":{"command":"ls"}}'; do
  fp_run "$_p"
  ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && [ -n "$fp_err" ] && ok=0
  check "GH #326 invalid JSON (raw control byte in a string / [ before an object body) reaches python3" "$ok"
done
fp_run '{"tool_name":"Bash","tool_input":{"command":"ls","x":{"y":1}}}'
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 object nested past depth 2 is outside the proof, reaches python3" "$ok"
fp_run '{"tool_name":"Bash","tool_input":{"command":"ls","x":[1]}}'
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = yes ] && ok=0
check "GH #326 array value is outside the proof, reaches python3" "$ok"
fp_run '{"tool_name":"Bash","tool_input":{"command":"ls","t":-1.5e3,"b":true,"n":null}, "x" : "a\"b\\/\n"}'
ok=1; [ "$fp_rc" -eq 0 ] && [ "$fp_py" = no ] && ok=0
check "GH #326 numbers, literals, spaces and \\\" \\\\ \\/ \\n escapes stay inside the proof (python $fp_py)" "$ok"

# --- GH #309: bash, ksh and zsh expand braces (dash does not), so a brace in the git word, the sub word or a
# wrapper word (`git {,stash}`, `{,doas} git stash`, `env{,} git stash`) hid the anchor or the sub word.
for _c in \
  'git {,stash}' \
  'git {stash,}' \
  'git -C . {,stash}' \
  '{,doas} git stash' \
  '{,env} git stash' \
  'doas{,} git stash' \
  'env{,} git stash' \
  'git {,reset} --hard' \
  'git {,clean} -fd' \
  'git {,"stash"}' \
  "git {,'stash'}" \
  'git {,stash$x}' \
  '{"git",} stash' \
  '{,"doas"} git stash' \
  '{,"env"} git stash' \
  'echo {x,#$}; git {,"stash"}' \
  $'# {x,y}\'\ngit {,"stash"}' \
  "bash -c 'git {,\"stash\"}'" \
  "bash -c 'git {,stash}'" \
  'git {stash,} $"show"' \
  $'true \\\\\ngit {,stash}' \
  $'gi\\\nt {,stash}' \
  'git {,stash} <(:)' ; do  # zsh and dash read $"show" as $show: a bare stash (the three `$` readings, GH #344)
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #309 denied (brace expands to a guarded git command): $_c" "$ok"
done
for _c in \
  'git {,status}' \
  'git {log,show}' \
  'git {,stash} list' \
  'git add src/{a,b}.py' \
  'echo "git {,stash}"' \
  'echo {a,b}' \
  'for i in {1..5000}; do echo $i; done' \
  'touch f{0..99}{0..99}.txt' \
  'ls {a,b}' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #309 control allowed: $_c" "$ok"
done
# A JSON here-string with chained objects is data (the deep-audit weighted-score call): allowed, not TooBig.
_c="python3 weighted-score.py <<< '{\"scores\": [{\"id\":\"a\",\"score\":9,\"max\":10,\"weight\":3,\"insufficient\":false},{\"id\":\"b\",\"score\":9,\"max\":10,\"weight\":2,\"insufficient\":false},{\"id\":\"c\",\"score\":8,\"max\":10,\"weight\":2,\"insufficient\":false},{\"id\":\"d\",\"score\":8,\"max\":10,\"weight\":2,\"insufficient\":false},{\"id\":\"e\",\"score\":8,\"max\":10,\"weight\":1,\"insufficient\":false}], \"floorPct\": 0.5}'"
rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
check "GH #309 control allowed: JSON here-string with chained objects" "$ok"
# A double-quoted bash -c body is expanded by the inner shell, so it is read as command text.
for _c in 'bash -c "git {,stash}"' 'sh -c "git {,reset} --hard"'; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" != "0" ] && ok=0
  check "GH #309 denied (double-quoted shell body): $_c" "$ok"
done
# The expanded reading has its own 150 KB cap, not the 16 KB cap on the raw command: a chained range with
# no git in it is allowed under the default cap (develop allowed all three), a hidden verb beside one is
# still denied, and an expansion over 150 KB is refused.
for _c in 'mkdir -p out/{a..z}/{a..z}/{a..j}' 'touch f{0..60}{0..60}.txt' 'echo {a..z}{a..z}{a..z}'; do
  rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #309 control allowed under the default cap: $_c (rc $rc)" "$ok"
done
_c='git {,stash}; echo {a..z}{a..z}{a..z}'
rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #309 denied under the default cap: a brace-hidden stash beside a big range (rc $rc)" "$ok"
_c='echo {a..z}{a..z}{a..z}{a..z}'
rc=$(unset MH_SGG_MAX_CMD_CHARS; sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #309 denied: an expansion over 150 KB is refused (rc $rc)" "$ok"
# Bash closes a brace group at "}" only after a comma, so "{A=1}},git}" is the two words "A=1}}" and "git".
# Bash does not read an expanded word as an assignment: it runs a command named "A=1}}" with git as an argument,
# so git does not run. The guard denies it anyway (its tokenizer reads "A=1}} git stash" as an assignment before
# git); an over-deny in the safe direction, pinned here so a change to it is noticed.
for _c in '{A=1}},git} stash' '{A=1}},git} reset --hard'; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" != "0" ] && ok=0
  check "GH #309 denied, conservatively (bash's closing-brace rule): $_c" "$ok"
done
# An escaped blank or separator is part of its word, so a "#" after it is no comment: bash runs the git behind it.
for _c in 'echo x\ #; git {,stash}' 'echo x\;#; git {,stash}' 'echo a\ #b; git {,reset} --hard' 'echo x\ #; git stash'; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #309 audit denied (a # after an escaped blank is not a comment): $_c" "$ok"
done
_c='echo x #; git {,stash}'
rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
check "GH #309 audit control allowed (a real comment hides its brace): $_c" "$ok"
# Both gates read braces through the one shared module, so the two cannot drift apart.
ok=0
for _g in subagent-git-guard.py irrecoverable.py; do
  grep -qE '^[[:space:]]*(import|from) _bracex\b' "$ROOT/hooks/gates/$_g" || ok=1
done
check "GH #309 both gates import the shared _bracex module" "$ok"
_c="ls $(_pad 'a{b,c}d ' 500); git {,stash}"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #309 padded braced words decided inside 8 s as deny (rc $rc, ${#_c} bytes)" "$ok"
_c="ls $(_pad 'a{b,c}d ' 500)"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
check "GH #309 padded braced words allow shape finishes inside 8 s (rc $rc, ${#_c} bytes)" "$ok"

# --- GH #520: an assignment before the command makes no difference to what runs: A="x y" git stash is
# git stash with A set. The quote mask turns a quoted value into blanks and Q letters, so the assignment
# walk stopped at the value and the git behind it was never anchored.
for _c in \
  'A="xy" git stash' \
  "A='x' git stash" \
  'A="x y" git stash' \
  "A='x y' git reset --hard" \
  'A="x;y" git stash' \
  'A="$(pwd)" git stash' \
  'A=x\ y git stash' \
  'A="x y" B=1 git stash' \
  'A="x y" B=z\ w git clean -fd' \
  'A="x y" env git stash' \
  'echo hi; A="x y" git stash' \
  'true && A="x y" git stash' \
  'A=1 B="x y" git stash' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
  check "GH #520 denied (assignment with a quoted or escaped value): $_c" "$ok"
done
for _c in \
  'A="x y" git status' \
  'A="x y" git stash list' \
  'A="x y" echo git stash' \
  'A="x y"' \
  'echo A="x y" git stash' \
  'A="x y" B=2' ; do
  rc=$(sgg_rc "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
  check "GH #520 control allowed: $_c" "$ok"
done
# The assignment walk must stay linear: 1500 quoted assignments before the command, both verdicts in 8 s.
_c="$(_pad 'A="x y" ' 1500)git stash"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "2" ] && ok=0
check "GH #520 1500 quoted assignments before git stash decided inside 8 s as deny (rc $rc, ${#_c} bytes)" "$ok"
_c="$(_pad 'A="x y" ' 1500)git status"
rc=$(sgg_rc8 "$_c"); ok=1; [ "$rc" = "0" ] && ok=0
check "GH #520 1500 quoted assignments before git status decided inside 8 s as allow (rc $rc, ${#_c} bytes)" "$ok"

# JSON nesting depth: an extra key nested ~140,000 deep makes json.load raise RecursionError ("Stack
# overflow ... while decoding a JSON array"); that used to hit the parse-error allow, so a subagent
# git stash ran. Depth overflow now fails closed for every payload; plain malformed JSON still allows.
_deep_file="$_JOURNAL_TMP/deep.json"
deep_rc() { # deep_rc <command> <agent_id or ""> <depth>; writes stderr to $_deep_file.err
  python3 -c '
import json, sys
cmd, aid, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
if aid:
    d["agent_id"] = aid
s = json.dumps(d)
print(s[:-1] + ", \"x\": " + "[" * n + "]" * n + "}")
' "$1" "$2" "$3" > "$_deep_file"
  bash "$GATE" < "$_deep_file" 2> "$_deep_file.err"
  echo $?
}
rc=$(deep_rc 'git stash' agent-x 140000); ok=1
[ "$rc" = "2" ] && /usr/bin/grep -q "nested too deep" "$_deep_file.err" && ok=0
check "JSON depth 140000, subagent git stash: denied with 'nested too deep' (rc $rc)" "$ok"
rc=$(deep_rc 'git status' agent-x 140000); ok=1; [ "$rc" = "2" ] && ok=0
check "JSON depth 140000, subagent git status: denied, fail-closed on the error type (rc $rc)" "$ok"
rc=$(deep_rc 'git status' '' 140000); ok=1; [ "$rc" = "2" ] && ok=0
check "JSON depth 140000, no agent_id: denied, main session too (rc $rc)" "$ok"
. "$ROOT/tests/_lib/memerr.sh"
rc=$(echo '{"tool_name":"Bash","tool_input":{"command":"git stash"},"agent_id":"agent-x"}' | memerr "$GATE" 2>"$_deep_file.err"; echo $?); ok=1
[ "$rc" = "2" ] && /usr/bin/grep -q "nested too deep" "$_deep_file.err" && ok=0
check "json.load MemoryError, subagent git stash: denied with 'nested too deep' (rc $rc)" "$ok"
# depth 500, not 1000: Python <=3.11 counts json nesting against sys.getrecursionlimit() (overflow at ~986).
rc=$(deep_rc 'git status' agent-x 500); ok=1; [ "$rc" = "0" ] && ok=0
check "JSON depth 500, subagent git status: still parses and allows (rc $rc)" "$ok"
rc=$(deep_rc 'git stash' agent-x 500); ok=1; [ "$rc" = "2" ] && /usr/bin/grep -q "may not run" "$_deep_file.err" && ok=0
check "JSON depth 500, subagent git stash: parses, denied by the git scan not the depth branch (rc $rc)" "$ok"
printf '%s' '{"tool_name": "Bash", "agent_id": "agent-x", "tool_input": {"command": "git sta' > "$_deep_file"
bash "$GATE" < "$_deep_file" 2> "$_deep_file.err"; rc=$?; ok=1
[ "$rc" = "0" ] && /usr/bin/grep -q "unparseable stdin, allowing" "$_deep_file.err" && ok=0
check "truncated JSON with agent_id: still allows with 'unparseable stdin, allowing' (rc $rc)" "$ok"
rc=$(deep_rc 'git stash' agent-x 1); ok=1; [ "$rc" = "2" ] && ok=0
check "shallow subagent git stash with an empty extra array: denied (rc $rc)" "$ok"

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
