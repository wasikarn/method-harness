#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# shellcheck disable=SC2154  # _many_c and the other helpers come from the sourced tests/_lib/gates-harness.sh
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates-other.sh
# Part 3 of 3 of the gate tests (see test-gates.sh); helpers in tests/_lib/gates-harness.sh.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"

echo "=== irrecoverable gate (part 3: GH #246 onward, fixture corpora) ==="
# GH #349: the narrow pieces read $'-f' in a substitution body as $-f (no blank before the dash), so push,
# reset, checkout, branch, stash and rm let a quoted flag through. The ambiguity check now also reads a view
# with $'..' decoded and $".." as "..". The fuzz also found three narrow pieces narrower than the main parser:
# reset now takes --h/--har, push a +refspec, and checkout a "." that ends at a substitution close.
# Cases (each checked against real shells) live in a fixture.
_ansi_corpus="$ROOT/tests/hooks/fixtures/irrecoverable-ansi-c-flag-cases.txt"
_ansi_want=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_ansi_corpus"); _ansi_got=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #349: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *) test_allow "$IRRECOVERABLE" "GH #349 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" ;;
    *) continue ;;
  esac
  _ansi_got=$((_ansi_got + 1))
done < "$_ansi_corpus"
if [ "$_ansi_want" -ge 20 ] && [ "$_ansi_got" = "$_ansi_want" ]; then
  echo "  ✅ GH #349: corpus replayed every case ($_ansi_got)"; pass=$((pass + 1))
else
  echo "  ❌ GH #349: corpus replayed $_ansi_got of $_ansi_want cases" >&2; fail=$((fail + 1))
fi
_ansi_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + "$" + chr(39) + "-" + "f" * 140000 + chr(39))')"
_timed_case "GH #349: a 140 KB \$'-f...' flag behind 100 git and 40 push anchors is found in bounded time" 2 "$_ansi_dos_cmd"
_ansi_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + ("$" + chr(39) + "-u" + chr(39) + " ") * 20000)')"
_timed_case "GH #349: 20000 \$'-u' words behind 100 git and 40 push anchors are allowed in bounded time" 0 "$_ansi_dos_cmd"

# GH #268: a brace inside a word made a second tokenization whose windows doubled the subagent
# work-budget count, so a long benign bash -c body was denied only when it carried a brace.
_long_body="git status; $(printf 'echo x; %.0s' $(seq 650))"
test_allow "$IRRECOVERABLE" 'GH #268 control: subagent, long benign bash -c body, no brace' \
  "$(bash_agent_payload "bash -c \"${_long_body}echo foo1\"" agent-268)"
test_allow "$IRRECOVERABLE" 'GH #268: subagent, long benign bash -c body, brace inside a word' \
  "$(bash_agent_payload "bash -c \"${_long_body}echo foo{1}\"" agent-268)"

# GH #269 F3: a brace token in a -c/-C value or in the sub slot hid the verb (the verb regex needed whitespace before it).
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,push} --force' \
  "$(bash_payload 'git -c {a=b,push} --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,branch} -D main' \
  "$(bash_payload 'git -c {a=b,branch} -D main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,reset} --hard' \
  "$(bash_payload 'git -c {a=b,reset} --hard')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,clean} -fdx' \
  "$(bash_payload 'git -c {a=b,clean} -fdx')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -C {.,push} -f' \
  "$(bash_payload 'git -C {.,push} -f origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: the brace sits in the sub slot itself' \
  "$(bash_payload 'git {push,} --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: stash inside a -c brace value' \
  "$(bash_payload 'git -c {a=b,stash} drop')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace -c values, read-only sub' \
  "$(bash_payload 'git -c {a=b,c=d} log')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace -C values, read-only sub' \
  "$(bash_payload 'git -C {a,b} status')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace in the sub slot, no destructive word' \
  "$(bash_payload 'git {log,show} --oneline')"

# GH #269 F4: the narrow rm piece only looked at the first flag, and the substitution body is an echo window.
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm -v -rf x)' \
  "$(bash_payload 'eval "$(echo rm -v -rf /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm --recursive --force x)' \
  "$(bash_payload 'eval "$(echo rm --recursive --force /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm -v -R -f x)' \
  "$(bash_payload 'eval "$(echo rm -v -R -f /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: nested backtick form' \
  "$(bash_payload 'eval "`echo $(echo rm -v -rf /tmp/x)`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: quoted ) form' \
  "$(bash_payload 'eval "$(echo "a)" ; echo rm -v -rf /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: case form' \
  "$(bash_payload 'eval "$(case x in x) echo rm -v -rf /tmp/x;; esac)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F4 control: eval of $(echo rm -v x), no recursive or force flag' \
  "$(bash_payload 'eval "$(echo rm -v /tmp/x)"')"

# GH #269 F1/F2: the narrow shapes had a ~400-char globals limit and a 200-char verb-to-flag limit.
_pad130=$(printf 'a %.0s' $(seq 130))
test_deny "$IRRECOVERABLE" 'GH #269 F1: eval, 100 -C globals, push --force' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push --force origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: eval, 100 -C globals, reset --hard' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'reset --hard)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: nested backtick form, 100 -C globals' \
  "$(bash_payload 'eval "`echo $(echo git '"$_many_c"'push --force origin main)`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: quoted ) form, 100 -C globals' \
  "$(bash_payload 'eval "$(echo "a)" ; echo git '"$_many_c"'push --force origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: case form, 100 -C globals' \
  "$(bash_payload 'eval "$(case x in x) echo git '"$_many_c"'push --force origin main;; esac)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: escaped-backtick form, 100 -C globals' \
  "$(bash_payload 'eval "\`echo git '"$_many_c"'push --force origin main\`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: the brace form inside eval, 100 -C globals' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push {--force,} origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, push, 130 words before --force' \
  "$(bash_payload 'eval "$(echo git push origin '"$_pad130"'--force)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, reset, 130 words before --hard' \
  "$(bash_payload 'eval "$(echo git reset '"$_pad130"'--hard)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, branch, 130 words before -D main' \
  "$(bash_payload 'eval "$(echo git branch '"$_pad130"'-D main)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F1 control: eval, 100 -C globals, read-only sub' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'log --oneline)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F1 control: eval, 100 -C globals, push without a force flag' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push origin main)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F2 control: eval, push with 130 words and no force flag' \
  "$(bash_payload 'eval "$(echo git push origin '"$_pad130"'main)"')"

# GH #309: bash, ksh and zsh expand a brace inside a word too (dash does not), so a brace glued to a flag,
# a sub word or an add argument hid the verb or flag from the token windows, which read it literally.
# Already denied before the fix (the brace-kept token shows the letter, or a whole-token brace sits next
# to a broad verb); kept so the fix cannot lose them.
for _c in \
  'git restore -S{W,} file.txt' \
  'git {,stash} drop' \
  '{,doas} git push --force origin main' \
  'env{,} git push --force origin main' ; do
  test_deny "$IRRECOVERABLE" "GH #309 regression: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'git add src/{a,b}.py' \
  'git add {README.md,LICENSE}' \
  'git push origin feat/{a,b}' \
  'rm src/{a,b}.txt' \
  'cp x.{txt,bak}' \
  'mkdir -p src/{a,b}' \
  'git diff HEAD~{1,2}' \
  'git log --format={a,b}' \
  'git commit -m "fix {a,b} parsing"' \
  'echo {a,b}' \
  'ls {a,b}' \
  'ls -l{a,h} x' \
  'git commit -m "{x,y}"' \
  'git log --format={%h,%s}' \
  "jq '{name,id}' file.json" \
  "curl -d '{\"a\":1,\"b\":2}' http://x" \
  "awk '{print \$1,\$2}' f" \
  'echo "git push --fo{rce,} origin main"' \
  'for i in {1..20000}; do echo $i; done' \
  'echo "{1..99999}"' \
  'touch f{0..99}{0..99}.txt' \
  'f() { echo {a,b}; }' \
  '{ git status; }' \
  'echo {a,b} # {c,d}' \
  'echo ${x,y}' ; do
  test_allow "$IRRECOVERABLE" "GH #309 control: a brace that expands to nothing destructive: $_c" "$(bash_payload "$_c")"
done
_timed_case "GH #309: 3000 braced words before a brace-hidden force flag are denied inside the hook timeout" 2 \
  "$(python3 -c "print('echo ' + 'a{b,c}d ' * 3000 + '; git push --fo{rce,rce} origin main')")"
_timed_case "GH #309: 20000 nested brace pairs before a force reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('{' * 20000 + 'x' + '}' * 20000 + '; git reset --hard')")"
_timed_case "GH #309: 30000 chained brace groups before a hidden reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('echo ' + '{a,b}' * 30000 + '; git {,\"reset\"} --hard')")"
# A body that blew the depth budget only in the brace view left the flag set, and the next (ifs-split)
# view read it as its own blow-out and returned no windows, so an IFS-hidden rm after it was never read.
for _u in 1000 2000; do
  test_deny "$IRRECOVERABLE" "a depth-budget flag from the brace view does not empty the next view ($_u-char eval body)" \
    "$(bash_payload "$(python3 - "$_u" <<'PY'
import sys
print("eval '$( " + "a" * int(sys.argv[1]) + "'{1..64} ; rm${IFS}-rf${IFS}/tmp/x", end="")
PY
)")"
done
# The 50-handover xargs bound was one counter for every reading: the main reading spent 26, so the ifs-split
# view stopped before it reached the IFS-hidden rm at the end. The bound is per reading.
test_deny "$IRRECOVERABLE" "26 xargs handovers in the main reading leave the ifs-split view its own 50" \
  "$(bash_payload "$(python3 - <<'PY'
print("echo a | xargs env true; " * 26 + "rm${IFS}-rf${IFS}/tmp/x", end="")
PY
)")"
# Stripping leading words one slice at a time copied the rest each step: 75k `!` took 19 s, past the 8 s timeout.
_quad_tail='rm${IFS}-rf${IFS}/tmp/x a{b} c$d'
_timed_case "74900 leading ! words before an IFS rm are stripped in linear time" 2 \
  "$(python3 -c 'import sys; print("! " * 74900 + sys.argv[1], end="")' "$_quad_tail")"
_timed_case "37450 env wrappers before an IFS rm are unwrapped in linear time" 2 \
  "$(python3 -c 'import sys; print("env " * 37450 + sys.argv[1], end="")' "$_quad_tail")"
# Each eval level re-read the same body from scratch, and stripped its `!` words quadratically: 20 KB under
# four evals took 25 s.
_timed_case "a 20 KB ! flood under four evals is denied inside the hook timeout" 2 \
  "$(python3 -c 'import sys; t = sys.argv[1]; print("eval eval eval eval " + "! " * ((20000 - 20 - len(t)) // 2) + t, end="")' "$_quad_tail")"
# Empty alternatives build no new text, so the budget never charged them: 26 groups of {,} made 2^26 empty
# strings (4.7 s, 1.8 GB), and at 27 the gate ran past the 8 s hook timeout and failed open on the raw reset.
# 28 groups: the old gate does not finish inside the 10 s timeout (rc 124), so the row is red there on any machine.
_timed_case "GH #309 audit: 28 chained {,} groups before a raw force reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('false && echo ' + '{,}' * 28 + '; git reset --hard')")"
# A character range is not charged per item either, and the head x tail product was never checked: 1.1M items times
# seven {,} groups copied 140M strings (12 s) before the only cap check.
_timed_case "GH #309 audit: a 1.1M-item range times seven {,} groups before a raw reset is denied inside the hook timeout" 2 \
  "$(python3 -c "print('echo {a..' + chr(0x10FFFF) + '}' + '{,}' * 7 + '; git reset --hard')")"
_timed_case "GH #309: nested groups whose real expansion (120000 chars) is under the cap are not denied for a double charge" 0 \
  "$(python3 -c "L = 30000; print('echo {{' + 'A' * L + ',' + 'B' * L + '},{' + 'C' * L + ',' + 'D' * L + '}}')")"
_timed_case "GH #309: a 60000-char word before a brace is allowed fast" 0 \
  "$(python3 -c "print('echo ' + 'a' * 60000 + '{b,c}')")"
test_deny "$IRRECOVERABLE" "GH #309: a brace expansion over the length cap denies, never skips the copy" \
  "$(bash_payload "git add $(python3 -c "print('a' * 70000)"){b,c,d}")"

# GH #336: $IFS splitting, a verb held in a variable, mkfs, chmod 777 and rm --no-preserve-root.
# Cases (each deny shape checked in real shells) live in a fixture. A WOULD_* line is a shadow rule
# (GH #337): allowed with a would_* journal row, and enforced once SHADOW_RULES drops it.
_c336="$ROOT/tests/hooks/fixtures/irrecoverable-336-cases.txt"
_enf336="$_JOURNAL_TMP/enforced-gates"
mkdir -p "$_enf336" && cp -R "$ROOT/hooks/gates/." "$_enf336/"
python3 - "$_enf336/irrecoverable.py" <<'EOF'
import re, sys
s, n = re.subn(r"^SHADOW_RULES = .*$", "SHADOW_RULES = frozenset()", open(sys.argv[1]).read(), flags=re.M)
assert n == 1
open(sys.argv[1], "w").write(s)
EOF
_would336() { # <decision> <rule> <cmd>: shadowed -> allow + one would_* row; enforced copy -> deny/ask
  local dec="$1" rule="$2" cmd="$3" j="$_JOURNAL_TMP/w336.jsonl" out rc rows
  : > "$j"
  out=$(bash_payload "$cmd" | MH_GATE_JOURNAL_PATH="$j" bash "$IRRECOVERABLE" 2>/dev/null); rc=$?
  rows=$(python3 -c 'import json,sys; print(sum(json.loads(l).get("decision") == "would_" + sys.argv[2] and json.loads(l).get("rule") == sys.argv[3] for l in open(sys.argv[1])))' "$j" "$dec" "$rule")
  if [[ "$rc" == "0" && -z "$out" && "$rows" == "1" ]]; then
    echo "  ✅ SHADOW would_$dec $rule: $cmd"; pass=$((pass + 1))
  else
    echo "  ❌ SHADOW would_$dec $rule expected (rc=0, no stdout, 1 row), got rc=$rc rows=$rows: $cmd" >&2; fail=$((fail + 1))
  fi
  if [[ "$dec" == "deny" ]]; then
    test_deny "$_enf336/irrecoverable.sh" "GH #336 enforced once promoted: $cmd" "$(bash_payload "$cmd")"
  else
    test_ask "$_enf336/irrecoverable.sh" "GH #336 enforced once promoted: $cmd" "$(bash_payload "$cmd")"
  fi
}
_want336=$(/usr/bin/grep -cE '^(DENY|ALLOW|WOULD_DENY|WOULD_ASK) ' "$_c336"); _got336=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #336: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a336.jsonl"
      test_allow "$IRRECOVERABLE" "GH #336 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a336.jsonl"
      if [ -s "$_JOURNAL_TMP/a336.jsonl" ]; then
        echo "  ❌ GH #336 control journaled a row (a shadow rule fired): ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    WOULD_DENY\ *) _r="${_line#WOULD_DENY }"; _would336 deny "${_r%% *}" "${_r#* }" ;;
    WOULD_ASK\ *) _r="${_line#WOULD_ASK }"; _would336 ask "${_r%% *}" "${_r#* }" ;;
    *) continue ;;
  esac
  _got336=$((_got336 + 1))
done < "$_c336"
# Each view re-reads the whole command (up to _VIEW_LEN_CAP), and a timed-out hook allows.
_pad336="$(printf 'echo a; %.0s' $(seq 1200))"
_timed_case "GH #336: var-verb view (shadow), target after 10 KB of statements, read in bounded time" 0 "${_pad336}X=rm; \$X -rf build"
_timed_case "GH #336: ifs-split view, target after 10 KB of statements, denied in bounded time" 2 "${_pad336}rm\${IFS}-rf build"
_timed_case "GH #336: var-verb view, 1200 references of one benign variable, allowed in bounded time" 0 "X=ls; $(printf 'echo $X %.0s' $(seq 1200))"
_timed_case "GH #336: chmod with 4000 a+rw words, allowed in bounded time" 0 "chmod -R $(printf 'a+rw %.0s' $(seq 4000))build"
# Padding past _VIEW_LEN_CAP (20,000) used to drop the enforced ifs-split view while the parser ran up
# to _CMD_LEN_CAP (150,000), so a 21 KB word in front of rm${IFS}-rf allowed it.
_big336="$(printf 'a%.0s' $(seq 21000))"
_timed_case "GH #336: ifs-split view, target after a 21 KB word, denied in bounded time" 2 "echo ${_big336}; rm\${IFS}-rf\${IFS}./build"
_timed_case "GH #336: ifs-split view, target after 48 KB of statements, denied in bounded time" 2 \
  "$(printf 'echo a; %.0s' $(seq 6000))rm\${IFS}-rf\${IFS}./build"
_timed_case "GH #336 control: a 21 KB heredoc is allowed in bounded time" 0 "cat > notes.txt <<'EOF'
${_big336}
EOF"
_timed_case "GH #336 control: a 21 KB heredoc with a plain assignment is allowed in bounded time" 0 "X=1; cat > notes.txt <<'EOF'
\$X ${_big336}
EOF"
if [ "$_want336" -ge 60 ] && [ "$_got336" = "$_want336" ]; then
  echo "  ✅ GH #336: corpus replayed every case ($_got336)"; pass=$((pass + 1))
else
  echo "  ❌ GH #336: corpus replayed $_got336 of $_want336 cases" >&2; fail=$((fail + 1))
fi

# GH #309: bash, ksh and zsh expand a brace inside a word too (dash does not), so a brace glued to a flag,
# a sub word, an add argument or argv0 hid the verb or flag from the token windows, which read it literally.
# The expanded text is read as the "brace-view" view, which ships shadow first (GH #337): each row is
# allowed with one would_deny row, and denied once the id leaves SHADOW_RULES (the enforced copy).
# ('git add {.,}' is not a row: the enforced copy also turns the shadowed source-file rule on, which asks
# for the literal '{ ., }' reading, so its stdout is not empty; it is the same bypass as 'git add {..,}'.)
for _c in \
  'fi{nd,nd} /tmp/x -delete' \
  'git restore -S --wor{ktree,} file.txt' \
  'git branch --del{ete,ete} --forc{e,e} main' \
  'git add {..,}' \
  'git add {-A,}' \
  'git add {:/,}' \
  'git add {*,}' \
  'git add {--pathspec-from-file=list,}' \
  'git add -{-pathspec-from-file=list,}' \
  'git {,add} .' \
  'git {,add} -A' \
  'git a{dd,dd} .' \
  'git -C . a{dd,dd} .' \
  'git rest{ore,ore} .' \
  'git br{anch,anch} -D main' \
  'fi{"nd",} /tmp -delete' \
  'git {,"reset"} --hard' \
  'git -C . {,"reset"} --hard' \
  'git {,"clean"} -fd' \
  "bash -c 'git {,\"reset\"} --hard'" \
  'echo {x,#$}; git {,"reset"} --hard' \
  $'# {x,y}\'\ngit {,"reset"} --hard' \
  '{f,"x y"}ind . -delete' \
  '{,git} reset --hard' \
  'git {{,},reset} --hard' \
  '{A=1}},git} reset --hard' \
  '{A="x y",git} reset --hard' \
  "{A='x y',git} reset --hard" \
  'f{ind,x\ y} /tmp/x -delete' \
  $'f{ind,x\ry} /tmp/x -delete' \
  'f{ind,<(:)} /tmp/x -delete' \
  'f{ind,>(: x)} /tmp/x -delete' \
  'chmod -R {777..0} /tmp/x' \
  'chmod {777..700} -R /' \
  'f{ind,>(: "a b")} /tmp/x -delete' ; do  # an escaped blank or quote inside the group: the fast path must reach python
  _would336 deny brace-view "$_c"
done
# GH #661: rm's own rules (rm-rf, rm-recursive, rm-no-preserve-root) enforce in brace-view: bash runs the
# rm these shapes build. The push rules enforce there too (below); every other rule stays shadow (GH #337).
for _c in \
  'r{m,m} -rf /tmp/x' \
  'r{"m",} -rf /tmp/x' \
  "r{'m',} -rf /tmp/x" \
  'r{\m,} -rf /tmp/x' \
  'r{m,$x} -rf /tmp/x' \
  '{r,}{m,} -rf /tmp/x' \
  '{r{m,},} -rf /tmp/x' \
  'r{m..m..1} -rf /tmp/x' \
  'rm {-rf,\ } /tmp/x' \
  '{r,"x y"}m -rf /tmp/x' \
  'r{{x},m} -rf /tmp/x' \
  '{A=1}},rm} -rf /tmp/x' \
  '{r..3}m -rf /tmp/x' \
  'r{m,x\ y} -rf /tmp/x' \
  'r{m,"x\"y z"} -rf /tmp/x' \
  $'true \\\\\nr{m,} -rf /tmp/x' \
  $'r\\\n{m,} -rf /tmp/x' \
  $'r{m,x\xc2\xa0y} -rf /tmp/x' \
  'echo <(r{m,} -rf /tmp/x)' \
  'r{m,<(: x)} -rf /tmp/x' \
  'echo x\ #; r{m,} -rf /tmp/x' \
  'echo x\;#; r{m,} -rf /tmp/x' \
  "r{m,<('\\')} -rf /tmp/x" ; do  # escaped blanks and quotes here too: the fast path must reach python
  test_deny "$IRRECOVERABLE" "GH #661: a brace-built rm -rf denies through brace-view: $_c" "$(bash_payload "$_c")"
done
# GH #309 push slice: git-push-force, git-push-mirror and git-push-delete-protected enforce in brace-view
# too, so a brace-built forced push denies. --for{ce-with-lease,} also carries --force-with-lease: git
# rejects its ambiguous --for, the gate denies it anyway.
for _c in \
  'git push --fo{rce,rce} origin main' \
  'git push --forc{e,e-with-lease} origin main' \
  'git push "--fo"{rce,} origin main' \
  'git push --forc{e..e} origin main' \
  'git pu{sh,} --force origin main' \
  'git {,"push"} --force origin main' \
  "git {,'push'} --force origin main" \
  'git push --fo{r,}{ce,} origin main' \
  'git push --fo{r{ce,x},} origin main' \
  'git push "--"{x,force} origin main' \
  "git push \$'--'{x,force} origin main" \
  'git push origin main {--forc,x}"e"' \
  'git push \--fo{rce,} origin main' \
  $'git push --fo{rce,\\\n} origin main' \
  'git push --forc{e..e..1} origin main' \
  '{$(:),git} push --force origin main' \
  '{,git} push --force origin main' \
  'env {,git} push --force origin main' \
  '{,git} push origin +main' \
  '{A=1}},git} push --force origin main' \
  'git push --for{ce-with-lease,} origin main' ; do
  test_deny "$IRRECOVERABLE" "GH #309: a brace-built forced push denies through brace-view: $_c" "$(bash_payload "$_c")"
done
# The .sh fast path hands a command to python only when brace-route.awk sees an expanding group, so the
# awk must see every shape _bracex expands: enumerate each string of { } , x . up to 7 characters (97,655; plus
# two wider alphabets with backslash, quote, blank, newline, CR, NBSP and "<("),
# wrap it in the hook payload, and fail on any that expands but is not routed (a single-level grep missed
# r{{x},m} and a stray "}" before the comma, "{A=1}},git}": GH #309 review). The same shapes up to 6
# characters are also run through the bash on PATH (echo), and _bracex must read the same words: it mirrors
# bash's own scan (a "}" closes a group only after a comma or "..", "{" then "}" at a word start is no group).
_drift=$(python3 - "$ROOT" <<'PYEOF'
import itertools, json, shutil, subprocess, sys
root = sys.argv[1]
sys.path.insert(0, root + "/hooks/gates")
import _bracex
cmds, shapes = [], []
for n in range(1, 8):
    for t in itertools.product("{},x.", repeat=n):
        c = "echo r" + "".join(t) + " -rf"
        try:
            e = _bracex.expand_text(c, 150000)
        except Exception:
            continue
        if e != c:
            cmds.append(c)
        if n <= 6:
            shapes.append((c, e.split()))
# Wider alphabets with a backslash, quotes, a blank, a newline, CR, NBSP and "<(" (up to 5 and 4 characters,
# routing only: most of these are not valid shell): "r{m,x\\ y} -rf" hid its verb from an awk that read the JSON escape pair, then the blank.
for alpha, top in (("{},x\\ \"'", 5), ("{},x\\ \n\r\xa0<()", 4)):
    for n in range(1, top + 1):
        for t in itertools.product(alpha, repeat=n):
            c = "echo r" + "".join(t) + " -rf"
            try:
                e = _bracex.expand_text(c, 150000)
            except Exception:
                continue
            if e not in (c, _bracex._strip_continuations(c)):  # a stripped line continuation alone is no expansion
                cmds.append(c)
pay = lambda c: json.dumps({"tool_name": "Bash", "tool_input": {"command": c}})
out = subprocess.run(["awk", "-f", root + "/hooks/gates/brace-route.awk"], input="\n".join(pay(c) for c in cmds) + "\n",
                     capture_output=True, text=True).stdout.split()
miss = [c for c, o in zip(cmds, out) if o == "0"]
bad, nbash = [], 0
bash = shutil.which("bash")
if bash:
    # On stdin, not one -c argument: ~19.5k shapes exceed Linux's 128 KiB per-argument cap (E2BIG).
    got = subprocess.run([bash], input="\n".join(c for c, _ in shapes) + "\n", capture_output=True, text=True).stdout.split("\n")[:-1]
    if len(got) == len(shapes):
        nbash = len(got)
        bad = [c for (c, e), g in zip(shapes, got) if g.split() != e[1:]]
print(len(cmds), len(out), len(miss), nbash, len(bad), " | ".join((miss + bad)[:5]))
PYEOF
)
read -r _dn _do _dm _bn _bb _drest <<< "$_drift"
# _bn must be well above 0: a bash that is missing or fails compared nothing, and "0 differences" then proved nothing.
if [ "${_dn:-0}" -gt 1000 ] && [ "$_dn" = "${_do:-x}" ] && [ "${_dm:-1}" = "0" ] && [ "${_bb:-1}" = "0" ] && [ "${_bn:-0}" -gt 1000 ]; then
  echo "  ✅ GH #309: brace-route.awk routes all $_dn enumerated brace shapes _bracex expands; _bracex matches bash on $_bn"
  pass=$((pass + 1))
else
  echo "  ❌ GH #309: brace-route.awk missed ${_dm:-?} of ${_dn:-?} expanding shapes, _bracex differs from bash on ${_bb:-?} of ${_bn:-?} (first: $_drest)" >&2
  fail=$((fail + 1))
fi
# An awk that starts but fails cannot vouch for a brace command: the fast path hands it to python (the
# over-cap expansion is a structural deny, so it enforces while brace-view is shadowed).
_BADAWK="$_JOURNAL_TMP/badawk"  # a subdir of the file's own temp dir: its EXIT trap cleans it
if mkdir "$_BADAWK"; then
  _badpay=$(bash_payload 'echo {a..z}{a..z}{a..z}{a..z}')
  for _stub in "exit 1:fails (exit 1)" "exit 0:prints nothing (exit 0)"; do
    printf '#!/bin/sh\n%s\n' "${_stub%%:*}" > "$_BADAWK/awk"; chmod +x "$_BADAWK/awk"
    _rc=$(echo "$_badpay" | PATH="$_BADAWK:$PATH" bash "$IRRECOVERABLE" >/dev/null 2>&1; echo $?)
    if [ "$_rc" = "2" ]; then
      echo "  ✅ GH #309: an awk that ${_stub#*:} sends the command to python (denied, rc 2)"
      pass=$((pass + 1))
    else
      echo "  ❌ GH #309: an awk that ${_stub#*:} must send the command to python, got rc $_rc" >&2
      fail=$((fail + 1))
    fi
  done
else
  echo "  ❌ GH #309: could not create the stub dir for the failing-awk rows" >&2
  fail=$((fail + 1))
fi
# A payload over 2000 characters with a "{" used to go to python unscanned; python's tokenizer then denied a
# heredoc line that mixes both quote marks (`v[:1] in '"\''`) that develop's fast path never sent there. The
# awk now bounds its own work, so a long f-string/dict heredoc with no expanding group stays on the fast path.
test_allow "$IRRECOVERABLE" "GH #309: a 2 KB python heredoc with braces and a mixed-quote line (no group expands) stays allowed" \
  "$(bash_payload "$(python3 -c "print(\"python3 - <<'PY'\\n\" + \"\".join(f\"x{i} = {{'a': {i}}}\\n\" for i in range(120)) + \"v[:1] in '\\\"\\\\''\\nPY\")")")"
# _deny_ambiguous returns inside brace-view only: any other view (ifs-split enforces) still ends on it.
if /usr/bin/grep -qE '_VIEW\[0\] == "brace-view"' "$ROOT/hooks/gates/irrecoverable.py"; then
  echo "  ✅ GH #309: _deny_ambiguous skips only the brace-view view"
  pass=$((pass + 1))
else
  echo "  ❌ GH #309: _deny_ambiguous must return only inside brace-view" >&2
  fail=$((fail + 1))
fi
# A structural deny takes no id, so it enforces even while brace-view is shadowed: a raw noncharacter
# (U+FDD0-U+FDEF, the expander's own stand-ins) is refused rather than read.
test_deny "$IRRECOVERABLE" "GH #309: a stand-in noncharacter in a command with a brace denies" \
  "$(bash_payload $'echo a\xef\xb7\x98\xef\xb7\x98E {x,"y"}\ngit {,"reset"} --hard\nE')"
# A private-use icon (Nerd Fonts live at U+E000) is an ordinary character, not a stand-in.
test_allow "$IRRECOVERABLE" "GH #309 control: a private-use icon in a command with a brace is allowed" \
  "$(bash_payload $'echo \xee\x80\x80 {a,b}')"
# A single-quoted span that is valid JSON is data, not a runnable command (the weighted-score call of
# every deep-audit): chained objects there used to multiply past the cap and deny. Anything that is not
# valid JSON is still read as command text (bash -c bodies), padded or not.
_json309='{"scores": [{"id":"a","score":9,"max":10,"weight":3,"insufficient":false},{"id":"b","score":9,"max":10,"weight":2,"insufficient":false},{"id":"c","score":8,"max":10,"weight":2,"insufficient":false},{"id":"d","score":8,"max":10,"weight":2,"insufficient":false},{"id":"e","score":8,"max":10,"weight":1,"insufficient":false}], "floorPct": 0.5}'
test_allow "$IRRECOVERABLE" "GH #309 control: a JSON here-string with chained objects is data, allowed (no TooBig)" \
  "$(bash_payload "python3 weighted-score.py <<< '$_json309'")"
test_deny "$IRRECOVERABLE" "GH #309: a bash -c body that only starts like JSON is still expanded (structural deny over the cap)" \
  "$(bash_payload "bash -c '$_json309; git {,\"reset\"} --hard'")"
_would336 deny brace-view "bash -c '{\"a\":1}; git {,\"reset\"} --hard; {x,y}'"
# A brace that cannot expand (no comma, no range: an f-string field, "{x}") stays on the shell fast path, so
# a heredoc body whose quotes the tokenizer cannot balance is not newly denied by the brace routing.
_c309h=$(cat <<'XEOF'
python3 - <<'EOF'
old = '''        secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
        if secs < 60: return f"{int(secs)}s"'''
new = '''        secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
        if secs < 0: return "0s"  # future/clock-skewed ts -- don't print a negative age
        if secs < 60: return f"{int(secs)}s"'''
for path in ["/tmp/test-dashboard.py", "commands/review-dashboard.md"]:
    with open(path) as f:
        content = f.read()
    if old in content:
        content = content.replace(old, new)
        with open(path, "w") as f:
            f.write(content)
        print("patched:", path)
    else:
        print("MISS:", path)
EOF
XEOF
)
test_allow "$IRRECOVERABLE" "GH #309 control: a heredoc with f-string braces and an apostrophe takes the fast path, allowed" \
  "$(bash_payload "$_c309h")"
# A double-quoted body can be a shell's command text (bash -c "..."), which expands braces itself, so double
# quotes are still read as command text. The cost is a known over-deny: a double-quoted JSON body with more
# than a few chained objects (curl -d "{...}") exceeds the cap and is denied.
test_deny "$IRRECOVERABLE" "GH #661: bash -c with a brace-built rm -rf denies" "$(bash_payload 'bash -c "r{m,} -rf /tmp/x"')"
# An uncaught error would exit 1, which does not block: 3000 nested substitutions must exit 2.
test_deny "$IRRECOVERABLE" "GH #309: 3000 nested dollar-paren spans in a command with a brace deny (exit 2, no traceback)" \
  "$(bash_payload "$(python3 -c "print('echo {a,b} ' + '\"\$(' * 3000)")")"

# _bracex unimportable (deleted, broken by an edit, a partial plugin cache): a command that could hold a
# brace expansion follows brace-view's own status instead of going unread. Shadowed: allowed with one
# would_deny row. Promoted: denied, nested shapes included. A brace that cannot expand (no "," or "..":
# ${HOME}, awk '{print}', find -exec {}) is left alone and writes no row. The documented over-deny while
# _bracex is broken: a real but harmless expansion (echo {a,b}) denies once brace-view is promoted.
_nobx="$_JOURNAL_TMP/no-bracex"; _nobx_enf="$_JOURNAL_TMP/no-bracex-enforced"
mkdir -p "$_nobx" "$_nobx_enf" && cp -R "$ROOT/hooks/gates/." "$_nobx/" && cp -R "$_enf336/." "$_nobx_enf/"
python3 - "$_nobx" "$_nobx_enf" <<'EOF'
import pathlib, shutil, sys
for d in map(pathlib.Path, sys.argv[1:]):
    (d / "_bracex.py").unlink()
    shutil.rmtree(d / "__pycache__", ignore_errors=True)
EOF
_jnb="$_JOURNAL_TMP/no-bracex.jsonl"; : > "$_jnb"
_onb=$(bash_payload 'r{m,} -rf /tmp/x' | MH_GATE_JOURNAL_PATH="$_jnb" bash "$_nobx/irrecoverable.sh" 2>/dev/null); _rnb=$?
_wnb=$(python3 -c 'import json,sys; print(sum(json.loads(l).get("decision") == "would_deny" and json.loads(l).get("rule") == "brace-view" for l in open(sys.argv[1])))' "$_jnb")
if [[ "$_rnb" == "0" && -z "$_onb" && "$_wnb" == "1" ]]; then
  echo "  ✅ _bracex missing, brace-view shadowed: a brace-hidden rm -rf allows with one would_deny row"; pass=$((pass + 1))
else
  echo "  ❌ _bracex missing, brace-view shadowed: expected rc=0, no stdout, 1 would_deny brace-view row; got rc=$_rnb rows=$_wnb" >&2; fail=$((fail + 1))
fi
test_deny "$_nobx_enf/irrecoverable.sh" "_bracex missing, brace-view promoted: a brace-hidden rm -rf denies" \
  "$(bash_payload 'r{m,} -rf /tmp/x')"
test_deny "$_nobx_enf/irrecoverable.sh" "_bracex missing, brace-view promoted: a nested brace with the comma outside denies" \
  "$(bash_payload 'r{m,x{y}} -rf /tmp/x')"
test_allow "$_nobx/irrecoverable.sh" "_bracex missing, brace-view shadowed: a harmless expansion allows" \
  "$(bash_payload 'echo {a,b}')" "MH_GATE_JOURNAL_PATH=$_jnb"
test_deny "$_nobx_enf/irrecoverable.sh" "_bracex missing, brace-view promoted: a harmless expansion denies (documented over-deny)" \
  "$(bash_payload 'echo {a,b}')"
_jnb2="$_JOURNAL_TMP/no-bracex-noexp.jsonl"; : > "$_jnb2"
for _c in 'echo ${HOME}/x' "awk '{print \$1}' f.txt" 'find . -name x -exec ls {} +' 'ls -la'; do
  test_allow "$_nobx_enf/irrecoverable.sh" "_bracex missing, brace-view promoted: a brace that cannot expand allows: $_c" \
    "$(bash_payload "$_c")" "MH_GATE_JOURNAL_PATH=$_jnb2"
  test_allow "$_nobx/irrecoverable.sh" "_bracex missing, brace-view shadowed: a brace that cannot expand allows: $_c" \
    "$(bash_payload "$_c")" "MH_GATE_JOURNAL_PATH=$_jnb2"
done
_rnb2=$(python3 -c 'import json,sys; print(sum(json.loads(l).get("rule") == "brace-view" for l in open(sys.argv[1])))' "$_jnb2")
if [[ "$_rnb2" == "0" ]]; then
  echo "  ✅ _bracex missing: a brace that cannot expand writes no brace-view row (gate-report stays clean)"; pass=$((pass + 1))
else
  echo "  ❌ _bracex missing: a brace that cannot expand wrote $_rnb2 brace-view row(s)" >&2; fail=$((fail + 1))
fi

# GH #375: a git global's value split by shlex at $, :, @ or a non-ASCII letter (-C $R) took the
# variable's name for the subcommand. Cases (each deny shape checked in real shells) live in a fixture.
_c375="$ROOT/tests/hooks/fixtures/irrecoverable-375-cases.txt"
_want375=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_c375"); _got375=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #375: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a375.jsonl"
      test_allow "$IRRECOVERABLE" "GH #375 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a375.jsonl"
      if [ -s "$_JOURNAL_TMP/a375.jsonl" ]; then
        echo "  ❌ GH #375 control journaled a row: ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    *) continue ;;
  esac
  _got375=$((_got375 + 1))
done < "$_c375"
# The re-read global part is one more window per git window; a hook timeout allows.
_timed_case "GH #375: 4000 '-C \$R' globals before reset --hard, denied in bounded time" 2 \
  "git $(printf -- '-C $R %.0s' $(seq 4000))reset --hard"
_timed_case "GH #375: 4000 '-C \$R' globals before status, allowed in bounded time" 0 \
  "git $(printf -- '-C $R %.0s' $(seq 4000))status"
_timed_case "GH #375: reset --hard after 2000 benign '-C \$R' git statements, denied in bounded time" 2 \
  "$(printf 'git -C $R status; %.0s' $(seq 2000))git -C \$R reset --hard"
_timed_case "GH #375: glue only inside the subcommand word appends no window, allowed in bounded time" 0 \
  "git -C \$R status\$X"
_timed_case "GH #375: 20 KB value of glued \$a\$b words before reset --hard, denied in bounded time" 2 \
  "git -C $(printf '$a%.0s' $(seq 10000)) reset --hard"
if [ "$_want375" -ge 50 ] && [ "$_got375" = "$_want375" ]; then
  echo "  ✅ GH #375: corpus replayed every case ($_got375)"; pass=$((pass + 1))
else
  echo "  ❌ GH #375: corpus replayed $_got375 of $_want375 cases" >&2; fail=$((fail + 1))
fi

# GH #405 F1: a ${...} or $(...) glued to a git global blanks into the same word (-C<PH>), which
# read only as a bare -C taking the subcommand as its value. Either expansion (empty or word-split
# " /repo") must be read; `-C${D} $R` checks the empty reading of the GH #375 window stays.
# F2: chmod reads its mode word only, so a file named 777 is not a mode.
for _c405 in 'git -C${R} reset --hard' 'git -C${R} push --force origin main' 'git -C${R:-.} reset --hard' \
    'git -C$(pwd) reset --hard' 'git --git-dir${G} reset --hard' 'git -C${D} /repo reset --hard' \
    'git -C${D} $R reset --hard' 'chmod -R 777 x' 'chmod -R a+rwx x' 'chmod 777 /' 'chmod a+rwx ~' 'chmod -R $(m) 777 x' 'chmod -R -- 777 x'; do
  test_deny "$IRRECOVERABLE" "GH #405: $_c405" "$(bash_payload "$_c405")"
done
# A substitution inside the flag name (-${X}C) is not its value, as on develop. chmod 777 on one
# plain path is out of the rule's scope (GH #336: recursive, / or ~ only).
for _c405 in 'git -C${R} status' 'git -C$(pwd) log --oneline' 'git -${X}C reset --hard' \
    'chmod -R 755 777' 'chmod -R 755 a+rwx' \
    'chmod 755 / 777' 'chmod 777 x' 'chmod a+rwx x'; do
  test_allow "$IRRECOVERABLE" "GH #405 control: $_c405" "$(bash_payload "$_c405")"
done
_timed_case "GH #405: reset --hard after 2000 benign '-C\${R}' git statements, denied in bounded time" 2 \
  "$(printf 'git -C${R} status; %.0s' $(seq 2000))git -C\${R} reset --hard"

# GH #409 R1: a comma mode is one shell word whose clauses are each a mode (the tokenizer cuts it at
# + and ,). R2: a word that is only an expansion ($V, "$V", $1) may be empty, so it is not the mode
# word. R3: a substitution before a git global's flag letters (${E}-C${R}) still carries its value.
for _c409 in 'chmod -R u+s,a+rwx x' 'chmod -R g+w,a+rwx /tmp/x' 'chmod -R a-x,a+rwx x' \
    'chmod -R +t,a+rwx x' 'chmod -R u=rwx,ugo=rwx x' 'chmod u+s,a+rwx /' 'chmod -R -x,a+rwx x' 'chmod -R x -x,a+rwx' \
    'chmod -R $V 777 /tmp/x' 'chmod $V 777 /' 'chmod $F -v 777 /' 'chmod -R $1 777 x' \
    'chmod -R $V a+rwx x' 'chmod -R "$V" 777 x' \
    'git ${E}-C${R} reset --hard' 'git $(true)-C$(pwd) reset --hard' 'git -${E}C${R} reset --hard' \
    'git ${E}-c${X} reset --hard' 'git ${E}-C${R} push --force'; do
  test_deny "$IRRECOVERABLE" "GH #409: $_c409" "$(bash_payload "$_c409")"
done
for _c409 in 'git -${X}C reset --hard' 'chmod -R 755 777' 'chmod -R 755 a+rwx' 'chmod 755 / 777' \
    'chmod 777 x' 'git -C${R} status' 'chmod -R u+s,g+w x' 'chmod -R $V 755 x'; do
  test_allow "$IRRECOVERABLE" "GH #409 control: $_c409" "$(bash_payload "$_c409")"
done
_timed_case "GH #409: a comma mode after 2000 benign chmod statements, denied in bounded time" 2 \
  "$(printf 'chmod 644 x; %.0s' $(seq 2000))chmod -R u+s,a+rwx x"

# GH #566: programs that run the command after them, beyond PREFIX_WRAPPERS.
test_deny  "$IRRECOVERABLE" "GH #566: flock LOCK git push --force" "$(bash_payload 'flock /tmp/l git push --force')"
test_deny  "$IRRECOVERABLE" "GH #566: caffeinate -i git push --force" "$(bash_payload 'caffeinate -i git push --force')"
test_deny  "$IRRECOVERABLE" "GH #566: xcrun git reset --hard" "$(bash_payload 'xcrun git reset --hard')"
test_deny  "$IRRECOVERABLE" "GH #566: watch -n1 git reset --hard" "$(bash_payload 'watch -n1 git reset --hard')"
test_deny  "$IRRECOVERABLE" "GH #566: strace -f rm -rf" "$(bash_payload 'strace -f rm -rf build')"
test_deny  "$IRRECOVERABLE" "GH #566: script -qc body" "$(bash_payload "script -qc 'rm -rf build' /dev/null")"
test_deny  "$IRRECOVERABLE" "GH #566: parallel rm -rf" "$(bash_payload 'parallel rm -rf ::: build')"
test_deny  "$IRRECOVERABLE" "GH #566: subagent: npx claude-code -p" "$(bash_agent_payload 'npx @anthropic-ai/claude-code -p hi' fork)"
test_deny  "$IRRECOVERABLE" "GH #566: subagent: flock LOCK claude -p" "$(bash_agent_payload 'flock /tmp/l claude -p hi' fork)"
test_allow "$IRRECOVERABLE" "GH #566 control: flock LOCK make" "$(bash_payload 'flock /tmp/l make')"
test_allow "$IRRECOVERABLE" "GH #566 control: watch -n2 git status" "$(bash_payload 'watch -n2 git status')"
test_allow "$IRRECOVERABLE" "GH #566 control: su - alice" "$(bash_payload 'su - alice')"
test_allow "$IRRECOVERABLE" "GH #566 control: subagent npx claude-code --version" "$(bash_agent_payload 'npx @anthropic-ai/claude-code --version' fork)"

# GH #382: the wrapper, assignment and argv0 walks read a split value ($U, a:b) or a dropped empty word
# ("") one token off. Every statement is also read as shell words (glued runs joined, "" kept).
_c382="$ROOT/tests/hooks/fixtures/irrecoverable-382-cases.txt"
_want382=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_c382"); _got382=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #382: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a382.jsonl"
      test_allow "$IRRECOVERABLE" "GH #382 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a382.jsonl"
      if [ -s "$_JOURNAL_TMP/a382.jsonl" ]; then
        echo "  ❌ GH #382 control journaled a row: ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    *) continue ;;
  esac
  _got382=$((_got382 + 1))
done < "$_c382"
# The word copy is one more window per statement that holds a split or empty word; a hook timeout allows.
_timed_case "GH #382: 4000 '-u \$U' sudo flags before git reset --hard, denied in bounded time" 2 \
  "sudo $(printf -- '-u $U %.0s' $(seq 4000))git reset --hard"
_timed_case "GH #382: 4000 '-u \$U' sudo flags before git status, allowed in bounded time" 0 \
  "sudo $(printf -- '-u $U %.0s' $(seq 4000))git status"
_timed_case "GH #382: rm -rf after 2000 benign 'X=\$Y make' statements, denied in bounded time" 2 \
  "$(printf 'X=$Y make; %.0s' $(seq 2000))X=\$Y rm -rf build"
_timed_case "GH #382: 20 KB glued \$a\$a sudo user before git reset --hard, denied in bounded time" 2 \
  "sudo -u $(printf '$a%.0s' $(seq 10000)) git reset --hard"
_timed_case "GH #382: 2000 empty -C values before reset --hard, denied in bounded time" 2 \
  "git $(printf -- '-C \"\" %.0s' $(seq 2000))reset --hard"
_timed_case "GH #382: 4000 empty words then git status, allowed in bounded time" 0 \
  "echo $(printf '\"\" %.0s' $(seq 4000)); git status"
if [ "$_want382" -ge 60 ] && [ "$_got382" = "$_want382" ]; then
  echo "  ✅ GH #382: corpus replayed every case ($_got382)"; pass=$((pass + 1))
else
  echo "  ❌ GH #382: corpus replayed $_got382 of $_want382 cases" >&2; fail=$((fail + 1))
fi

# GH #561: config a -c pair gives a git run (or a `git config` write stores) re-enables a denied action.
test_deny  "$IRRECOVERABLE" "GH #561: -c remote.origin.mirror=true push" "$(bash_payload 'git -c remote.origin.mirror=true push origin')"
test_deny  "$IRRECOVERABLE" "GH #561: -c remote.origin.push=+ refspec push" \
  "$(bash_payload 'git -c remote.origin.push=+HEAD:refs/heads/main push origin')"
test_deny  "$IRRECOVERABLE" "GH #561: -c alias running push --force" "$(bash_payload "git -c alias.p='push --force' p origin main")"
test_deny  "$IRRECOVERABLE" "GH #561: -c ! alias running rm -rf" "$(bash_payload "git -c alias.x='!rm -rf build' x")"
test_deny  "$IRRECOVERABLE" "GH #561: -c clean.requireForce=false clean" "$(bash_payload 'git -c clean.requireForce=false clean -dx')"
test_deny  "$IRRECOVERABLE" "GH #561: -c gc expiry at now" \
  "$(bash_payload 'git -c gc.reflogExpire=now -c gc.reflogExpireUnreachable=now -c gc.pruneExpire=now gc')"
test_deny  "$IRRECOVERABLE" "GH #561: git config storing a push --force alias" "$(bash_payload "git config alias.p 'push --force'")"
test_deny  "$IRRECOVERABLE" "GH #561: git config remote.origin.mirror true" "$(bash_payload 'git config remote.origin.mirror true')"
test_allow "$IRRECOVERABLE" "GH #561 control: -c alias.st=status st" "$(bash_payload 'git -c alias.st=status st')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config alias.lg log" "$(bash_payload "git config alias.lg 'log --oneline --graph'")"
test_allow "$IRRECOVERABLE" "GH #561 control: requireForce=false clean -n" "$(bash_payload 'git -c clean.requireForce=false clean -n')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config gc.pruneExpire 2.weeks.ago" "$(bash_payload 'git config gc.pruneExpire 2.weeks.ago')"

# GH #608: a command an interpreter one-liner hands to a process API, in a string literal or an argv list.
test_deny  "$IRRECOVERABLE" "GH #608: python os.system rm -rf" "$(bash_payload "python3 -c 'import os; os.system(\"rm -rf build\")'")"
test_deny  "$IRRECOVERABLE" "GH #608: python subprocess argv list" \
  "$(bash_payload "python3 -c 'import subprocess; subprocess.run([\"git\", \"push\", \"--force\"])'")"
test_deny  "$IRRECOVERABLE" "GH #608: perl system" "$(bash_payload "perl -e 'system(\"git reset --hard\")'")"
test_deny  "$IRRECOVERABLE" "GH #608: perl qx{}" "$(bash_payload "perl -e 'qx{rm -rf build}'")"
test_deny  "$IRRECOVERABLE" "GH #608: node execFileSync argv" \
  "$(bash_payload "node -e \"require('child_process').execFileSync('git', ['push', '--force'])\"")"
test_deny  "$IRRECOVERABLE" "GH #608: ruby %x()" "$(bash_payload "ruby -e '%x(rm -rf build)'")"
test_allow "$IRRECOVERABLE" "GH #608 control: print naming rm -rf (no process API)" "$(bash_payload "python3 -c 'print(\"rm -rf is denied\")'")"
test_allow "$IRRECOVERABLE" "GH #608 control: subprocess git status" \
  "$(bash_payload "python3 -c 'import subprocess; print(subprocess.check_output([\"git\", \"status\"]))'")"
test_allow "$IRRECOVERABLE" "GH #608 control: perl -ne matching rm -rf" "$(bash_payload "perl -ne 'print if /rm -rf/' f.txt")"
_timed_case 'GH #608: 16000 distinct literals in a process-API body are read in bounded time' 0 \
  "python3 -c 'import os; os.system($(python3 -c "print(''.join('\"l%d\", ' % i for i in range(16000)))")\"x\")'"
# GH #593: the assignment scan is one non-overlapping pass; a chain-matching regex over these took 40 s
_timed_case "GH #593: rm -rf before 10000 prefix assignments, denied in bounded time" 2 \
  "rm -rf build; $(printf 'a=b %.0s' $(seq 10000))x"
_timed_case "GH #593: rm -rf before 10000 escaped-blank assignments, denied in bounded time" 2 \
  "rm -rf build; $(printf 'x=\\ %.0s' $(seq 10000))"

gates_summary
