#!/usr/bin/env bash
# _quotemask.py unit tests, and the missing-module behaviour of its two consumers. Both subagent-git-guard.py and
# test-integrity.py import mask_quotes from this shared module (2026-09-20,
# deferred finding #10 follow-up, after the two files' own copies drifted
# into byte-identical duplicates that each independently missed the same
# "#"-comment bug). This test proves: (1) the shared module itself handles
# the known bug classes, and (2) both consumers import it and, without it, allow with a stderr note (GH #892).
# Run standalone: bash tests/hooks/test-quotemask.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0

check() {
  local desc="$1" ok="$2"
  if [ "$ok" -eq 0 ]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

mask() {
  python3 -c "
import sys
sys.path.insert(0, '$ROOT/hooks/gates')
from _quotemask import mask_quotes
print(mask_quotes(sys.argv[1]), end='')
" "$1"
}

echo "=== _quotemask.py: mask_quotes() unit tests ==="
echo ""

OUT=$(mask 'git reset --hard')
ok=1; [ "$OUT" = "git reset --hard" ] && ok=0
check "plain command, no quotes -> unchanged" "$ok"

OUT=$(mask "echo 'a; b'")
ok=1; [[ "$OUT" != *";"* ]] && ok=0
check "separator inside single quotes is masked" "$ok"

OUT=$(mask "echo hi # don't remove
git reset --hard")
ok=1; [[ "$OUT" == *$'\n'"git reset --hard" ]] && ok=0
check "comment apostrophe before real content: 'git reset --hard' survives on its own line" "$ok"

OUT=$(mask 'git reset --hard # comment after, with an apostrophe don'"'"'t matter')
ok=1; [[ "$OUT" == "git reset --hard"* ]] && ok=0
check "comment apostrophe AFTER the real command: command text stays intact" "$ok"

# 2026-09-21 deep-audit: ")" is a bash metacharacter, so "#" right after it
# starts a comment ("(true)#don't" is a comment from "#" on), but it was
# missing from _WORD_BOUNDARY_CHARS -- the apostrophe opened a fake
# single-quote span that masked the real "git stash" on the next line away.
OUT=$(mask "(true)#don't
git stash")
ok=1; [[ "$OUT" == *$'\n'"git stash" ]] && ok=0
check "comment right after a ')' (metacharacter): 'git stash' on the next line survives" "$ok"

# Control: a backtick is NOT a metacharacter, so "\`true\`#don't" is one word
# and the "'" really does open a quote in bash -- must still be masked.
OUT=$(mask "\`true\`#don't
git stash")
ok=1; [[ "$OUT" != *"git stash" ]] && ok=0
check "control: '#' right after a backtick is not a comment, the quote span still masks" "$ok"

# GH #157 sibling (2026-09-21): a backslash-escaped quote OUTSIDE a span is
# a literal character in real bash, never a span opener -- an odd backslash
# run escapes the quote, an even run is literal backslashes and leaves the
# quote live. The old masker opened a span at any bare quote, so
# `echo \" ; git stash` masked the real "git stash" away: a bypass.
OUT=$(mask 'echo \" ; git stash')
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "escaped double quote outside a span is literal (odd run): 'git stash' after it survives" "$ok"

OUT=$(mask "echo \\' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "escaped single quote outside a span is literal (odd run): 'git stash' after it survives" "$ok"

OUT=$(mask 'echo \\" ; git stash"')
ok=1; [[ "$OUT" != *"git stash"* ]] && ok=0
check "even backslash run before a double quote leaves the quote live: span still masks" "$ok"

OUT=$(mask "echo \\\\' ; git stash'")
ok=1; [[ "$OUT" != *"git stash"* ]] && ok=0
check "even backslash run before a single quote leaves the quote live: span still masks" "$ok"

OUT=$(mask "echo '\\' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "backslash inside single quotes is literal: the span closes at the next quote, 'git stash' survives" "$ok"

OUT=$(mask 'echo "\" ; git stash"')
ok=1; [[ "$OUT" != *"git stash"* ]] && ok=0
check "control: backslash-escaped quote INSIDE a double-quoted span stays inside it" "$ok"

# GH #161 (2026-09-21): bash ANSI-C quoting $'...' -- a backslash inside it
# escapes the next char, so $'\'' is a complete one-apostrophe string. The
# old masker saw the bare "'" and masked the rest of the line, so
# `echo $'\'' ; git stash` hid the real "git stash": a bypass (false ALLOW).
OUT=$(mask "echo \$'\\'' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "ANSI-C \$'\\'' is one complete span: 'git stash' after it survives" "$ok"

OUT=$(mask "echo \$'a\\'b' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "ANSI-C \$'a\\'b' is one span: 'git stash' after it survives" "$ok"

OUT=$(mask "echo \$'x' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "ANSI-C \$'x' then a real stash: 'git stash' stays visible" "$ok"

OUT=$(mask "echo \$'a ; git stash'")
ok=1; [[ "$OUT" != *"git stash"* ]] && ok=0
check "control: stash INSIDE an ANSI-C span is masked" "$ok"

OUT=$(mask 'echo $x ; git stash')
ok=1; [ "$OUT" = 'echo $x ; git stash' ] && ok=0
check "a \$ not followed by a quote is untouched" "$ok"

OUT=$(mask "echo \"\$'\" ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "\$' inside a double-quoted span stays inside it: 'git stash' after the span survives" "$ok"

# Backslash-newline (odd run) is a line continuation (GH #286). Masked as
# blanks at a word start so `\<nl>git stash` still shows git to the callers'
# anchor (2026-09-21 validator round 2 bypass); masked as Q's mid-word so a
# "#" after it is not a comment.
OUT=$(mask $'echo \\\ngit stash')
ok=1; [ "$OUT" = 'echo   git stash' ] && ok=0
check "backslash-newline at a word start is blanks, git stays visible" "$ok"

OUT=$(mask $'echo x\\\n#y; git stash')
ok=1; [ "$OUT" = 'echo   x#y; git stash' ] && ok=0
check "GH #286: hash after a mid-word line continuation is not a comment" "$ok"

# GH #309 audit: an escaped blank or separator is part of its word, so the "#" after it is no comment
OUT=$(mask 'echo x\ #; git stash')
ok=1; [ "$OUT" = 'echo x\ #; git stash' ] && ok=0
check "GH #309 audit: hash after an escaped blank is not a comment" "$ok"
OUT=$(mask 'echo x\;#; git stash')
ok=1; [ "$OUT" = 'echo x\;#; git stash' ] && ok=0
check "GH #309 audit: hash after an escaped semicolon is not a comment" "$ok"
OUT=$(mask 'echo x #; git stash')
ok=1; [ "$OUT" = 'echo x             ' ] && ok=0
check "GH #309 audit control: a real comment still masks to the end of the line" "$ok"

OUT=$(mask $'echo x \\\n#y; git stash')
ok=1; [[ "$OUT" != *"stash"* && "$OUT" == "echo x "* ]] && ok=0
check "GH #286 control: continuation then hash at a word start is still a comment" "$ok"

OUT=$(mask $'echo x\n#y; git stash')
ok=1; [[ "$OUT" != *"stash"* && "$OUT" == "echo x"$'\n'* ]] && ok=0
check "GH #286 control: hash after a plain newline is still a comment" "$ok"

OUT=$(mask $'echo x\\\\\n#y; git stash')
ok=1; [[ "$OUT" == "echo x"* && "$OUT" != *"stash"* && "$OUT" != *QQ* ]] && ok=0
check "GH #286 control: even backslash run before newline is not a continuation" "$ok"

OUT=$(mask $'echo x\\\\\\\n#y; git stash')
ok=1; [ "$OUT" = $'echo   x\\\\#y; git stash' ] && ok=0
check "GH #286: odd run of 3 is escaped backslash plus continuation" "$ok"

OUT=$(mask $'git\\\nstash')
ok=1; [ "$OUT" = '  gitstash' ] && ok=0
check "GH #286: continuation inside a word glues it" "$ok"

# GH #306: the shell deletes the pair. When a blank, separator or the end follows, nothing glues:
# the pair is blanks in place. When a word char follows, the two halves join into one word: the
# blanks go to the front of that word, so the joined word reads whole and every char after the
# pair keeps its offset.
OUT=$(mask $'git\\\n stash')
ok=1; [ "$OUT" = 'git   stash' ] && ok=0
check "GH #306: continuation then a blank does not glue the next word" "$ok"

OUT=$(mask $'git stash\\\n')
ok=1; [ "$OUT" = 'git stash  ' ] && ok=0
check "GH #306: trailing continuation is blanks" "$ok"

OUT=$(mask $'git\\\n;x')
ok=1; [ "$OUT" = 'git  ;x' ] && ok=0
check "GH #306: continuation then a separator is blanks" "$ok"

OUT=$(mask $'g\\\nit stash')
ok=1; [ "$OUT" = '  git stash' ] && ok=0
check "GH #306: mid-word continuation joins the word (git readable)" "$ok"

OUT=$(mask $'echo g\\\ni\\\nt st\\\nash')
ok=1; [ "$OUT" = 'echo     git   stash' ] && ok=0
check "GH #306: several continuations in a word all pad its front" "$ok"

OUT=$(mask $'\'\'\\\ngit stash')
ok=1; [ "$OUT" = '    git stash' ] && ok=0
check "GH #306: continuation after a quoted word char joins it" "$ok"

OUT=$(mask $'bash -\\\nc "x"')
ok=1; [ "$OUT" = 'bash   -c  Q ' ] && ok=0
check "GH #306: chars after a joined pair keep their offsets (c at 8, quote at 10, as in the raw text)" "$ok"

# Round 2: a "$" is only an ANSI-C opener when it is itself live. An odd
# backslash run before it makes it literal ("\$'a\'" is a plain single-quoted
# string in bash), and an even run of "$" ("$$" is the PID) leaves the
# following quote plain. "$$$'x'" is "$$" then a real "$'x'".
OUT=$(mask "\\\$'a\\'; git stash; echo 'x'")
ok=1; [[ "$OUT" == *"; git stash; echo "* ]] && ok=0
check "escaped \\\$ then a plain single-quoted string: 'git stash' after it survives" "$ok"

OUT=$(mask "\$\$'a\\'; git stash; echo 'x'")
ok=1; [[ "$OUT" == *"; git stash; echo "* ]] && ok=0
check "\$\$ (PID) then a plain single-quoted string: 'git stash' after it survives" "$ok"

OUT=$(mask "\$\$\$'a\\'' ; git stash")
ok=1; [[ "$OUT" == *"; git stash" ]] && ok=0
check "\$\$\$'a\\'' is \$\$ then a real ANSI-C span: 'git stash' after it survives" "$ok"

echo ""
echo "=== both consumers import the shared module, and allow with a note when it is missing (GH #892) ==="
echo ""

ok=1; command grep -q "from _quotemask import mask_quotes" "$ROOT/hooks/gates/subagent-git-guard.py" && ok=0
check "subagent-git-guard.py imports mask_quotes from _quotemask" "$ok"

ok=1; command grep -q "from _quotemask import mask_quotes" "$ROOT/hooks/gates/test-integrity.py" && ok=0
check "test-integrity.py imports mask_quotes from _quotemask" "$ok"

# A copy of the gates dir without _quotemask.py: each gate runs on a payload it would otherwise judge, and must
# exit 0 with a stderr note naming the module. The real hooks/gates dir is never touched.
TMPG=$(mktemp -d)
cleanup() { [ -n "${TMPG:-}" ] && python3 "$ROOT/scripts/_lib/tmp_delete.py" "$TMPG"; }
trap cleanup EXIT
cp -R "$ROOT/hooks/gates/." "$TMPG/"
python3 "$ROOT/scripts/_lib/tmp_delete.py" "$TMPG/_quotemask.py"
ERR=$(printf '%s' '{"tool_name":"Bash","agent_id":"x","tool_input":{"command":"git reset --hard"}}' | MH_GATE_JOURNAL_PATH=/dev/null python3 "$TMPG/subagent-git-guard.py" 2>&1 >/dev/null); RC=$?
ok=1; [ "$RC" -eq 0 ] && [[ "$ERR" == *"_quotemask not importable"* ]] && ok=0
check "subagent-git-guard.py without _quotemask.py: exit 0 and a stderr note naming the module (rc=$RC)" "$ok"

ERR=$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"tests/hooks/test-x.sh","old_string":"[ \"$fail\" -eq 0 ]","new_string":"true"}}' | MH_GATE_JOURNAL_PATH=/dev/null python3 "$TMPG/test-integrity.py" 2>&1 >/dev/null); RC=$?
ok=1; [ "$RC" -eq 0 ] && [[ "$ERR" == *"_quotemask not importable"* ]] && ok=0
check "test-integrity.py without _quotemask.py: exit 0 and a stderr note naming the module (rc=$RC)" "$ok"

# Control: with the module present the same subagent payload is denied, so the exit 0 above is the new path.
ERR=$(printf '%s' '{"tool_name":"Bash","agent_id":"x","tool_input":{"command":"git reset --hard"}}' | MH_GATE_JOURNAL_PATH=/dev/null python3 "$ROOT/hooks/gates/subagent-git-guard.py" 2>&1 >/dev/null); RC=$?
ok=1; [ "$RC" -eq 2 ] && ok=0
check "control: the same payload with _quotemask.py present is denied (rc=$RC)" "$ok"

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
