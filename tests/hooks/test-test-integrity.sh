#!/usr/bin/env bash
# Behavioral tests for hooks/gates/test-integrity.sh. Covers the content-diff
# classifier (assertion removed -> ask, skip marker added -> ask, an added
# always-false conditional/loop wrap around a kept assertion -> ask across
# its if/elif/while and bracket/bare-test spellings), the path narrowing to
# real test-root shapes (not a bare "test"/"spec" substring), and the
# negative controls the adversarial plan review demanded: new-file test
# creation, an edit that only adds an assertion, a non-test path that merely
# contains "test"/"spec" as a substring, and the always-TRUE `[ 0 ]`/
# `[[ false ]]` single-operand tests (must all stay silent). Also proves a
# documented gap stays a documented gap (moving an assertion into an
# uncalled function evades the diff by design, not by accident).
# Run standalone: bash tests/hooks/test-test-integrity.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/gates/test-integrity.sh"
WORK=$(mktemp -d)
trap 'python3 "$ROOT/tests/_lib/tmp_delete.py" "$WORK"' EXIT
# Isolate the gate-verdict journal (hooks/gates/_journal.py) from this file's
# ask-case assertions -- run standalone (this file's own header invites it),
# it would otherwise silently append rows to the operator's real
# ~/.local/share/kbg/metrics/gate-decisions.jsonl.
export MH_GATE_JOURNAL_PATH="$WORK/gate-decisions.jsonl"

pass=0
fail=0

payload_edit() { # payload_edit <file_path> <old_string> <new_string>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"
}

payload_write() { # payload_write <file_path> <content>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

is_ask() { /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$1"; }

echo "=== test-integrity gate ==="
cd "$ROOT" || exit 1

TESTFILE="$WORK/tests/hooks/test-sample.sh"
mkdir -p "$(dirname "$TESTFILE")"
cat > "$TESTFILE" <<'EOF'
#!/usr/bin/env bash
check "case one" "$ok1"
check "case two" "$ok2"
EOF

# --- Positive: removing a check() call -> ask ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' '' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit removing a check() assertion -> ask" "$ok"

# jest/vitest: removing an expect() from a .spec.ts must ask (rev-2 audit FAIL, 2026-09-05)
SPEC="$WORK/src/foo.spec.ts"; mkdir -p "$(dirname "$SPEC")"
printf 'it("x", () => {\n  expect(a).toBe(1);\n  expect(b).toBe(2);\n});\n' > "$SPEC"
out=$(payload_edit "$SPEC" '  expect(b).toBe(2);' '' | bash "$GATE" 2>/dev/null)
is_ask "$out"; ok=$?
check "Edit removing a jest expect() from .spec.ts -> ask" "$ok"

# --- Positive: adding a skip marker -> ask ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' '# SKIP: check "case two" "$ok2"' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit adding a # SKIP marker -> ask" "$ok"

# --- Positive: wrapping a kept assertion in an always-false conditional
# still counts as disabling it, even though the assertion's own line text
# is unchanged (real bypass found by a compliance audit, 2026-08-28) ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if false; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit wrapping an assertion in 'if false; then...fi' -> ask" "$ok"

# --- Positive: the same always-false wrap in its other common spellings
# (elif/while, bracket/bare-test numeric comparisons other than 0/1) --
# a deep-audit fresh-context check (2026-08-28) found these bypassed the
# first version of the fix above; verified live with real bash truthiness
# before adding, not assumed from the regex text. ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if [ 1 -eq 2 ]; then
echo x
elif false; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit wrapping an assertion in 'elif false' -> ask" "$ok"

out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'while false; do
check "case two" "$ok2"
done' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit wrapping an assertion in 'while false; do...done' -> ask" "$ok"

out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if [ 1 -eq 2 ]; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit wrapping an assertion in 'if [ 1 -eq 2 ]' (non-0/1 literals) -> ask" "$ok"

out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if test 0 -eq 1; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit wrapping an assertion in bare 'if test 0 -eq 1' (no brackets) -> ask" "$ok"

# --- Negative: `[ 0 ]` and `[[ false ]]` are single-operand string tests --
# bash evaluates a non-empty string as TRUE regardless of its text, so
# neither actually disables the wrapped assertion. Matching them would be
# a false positive, not a closed gap -- verified live before asserting. ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if [ 0 ]; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit wrapping an assertion in 'if [ 0 ]' (always true) -> noask" "$ok"

out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'if [[ false ]]; then
check "case two" "$ok2"
fi' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit wrapping an assertion in 'if [[ false ]]' (always true) -> noask" "$ok"

# --- Documented gap, not silently unhandled: moving an assertion into a
# function that's never called evades the line-set diff entirely (no
# control-flow/reachability analysis here) -- see the gate's own header. ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'never_called() {
check "case two" "$ok2"
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit moving an assertion into an uncalled function -> noask (documented gap)" "$ok"

# --- Positive: redefining the check() oracle itself to a no-op silently
# guts every call site without touching a single one of them (deep-audit
# 2026-08-28, confirmed live: call sites stay byte-identical, only the
# helper's own meaning changes -- not a reachability trick, a straight
# diff on the shared assertion helper). ---
out=$(payload_edit "$TESTFILE" 'check() {
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit redefining the check() oracle to a no-op -> ask" "$ok"

# --- Positive: 2026-09-20 audit -- FUNC_BLOCK_RE's .search() only ever found
# the FIRST check(){...} definition, so a SECOND definition appended after a
# real one shadowed it at runtime (bash executes whichever was defined most
# recently) while the diff kept comparing against the untouched first one --
# a live, confirmed bypass. The fix takes the LAST definition found. ---
# old_string/new_string must carry the WHOLE original check() block in both
# (same shape as the "redefining check()" test above): the ORIGINAL, real
# definition stays byte-identical, and new_string appends a SECOND, no-op
# definition after it. Bash executes whichever was defined most recently, so
# the second definition is the one that actually runs -- but the old
# .search()-based regex only ever found the FIRST match, comparing the
# unchanged real body against itself and missing the shadowing no-op
# entirely (a live, confirmed bypass). The fix takes the LAST definition.
out=$(payload_edit "$TESTFILE" 'check() {
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}
check() {
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit appending a SECOND, shadowing no-op check() def -> ask (was silently missed by .search()'s first-match-only)" "$ok"

# --- Positive: 2026-09-20 audit -- a decoy nested '{ ... }' block whose own
# closing brace sits alone on its own line (e.g. an anonymous command group)
# truncated the old non-greedy '.*?' regex at that FIRST bare '}' line, so
# the diff never saw the real assertion logic sitting after the decoy -- a
# live, confirmed bypass. old_string/new_string must carry the WHOLE
# check(){...} block (this gate diffs Edit's old_string/new_string directly,
# not the file on disk -- same shape as the "redefining check()" test above),
# both containing the identical decoy but differing only in the real logic
# after it. The fix walks brace depth to find the function's REAL closing
# brace, so it must still see that difference. ---
out=$(payload_edit "$TESTFILE" 'check() {
  {
    :
  }
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  {
    :
  }
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after a decoy nested brace -> ask (was silently truncated past by the old non-greedy regex)" "$ok"

# --- Positive: compliance-audit fix-round 2, 2026-09-20 -- the brace-depth
# scanner above still wasn't quote-aware: a literal '}' inside a double-
# quoted string ("decoy }") was counted as a real closing brace, ending the
# scan before the real assertion -- live-confirmed to make helper_changed
# False for old_string/new_string that differ only after the quoted decoy.
# Fixed by quote-masking before the brace walk (same posture as
# subagent-git-guard.py's own _mask_quotes). ---
out=$(payload_edit "$TESTFILE" 'check() {
  echo "decoy }"
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  echo "decoy }"
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after a QUOTED decoy brace -> ask (was silently truncated past by the old quote-unaware scanner)" "$ok"

# --- Positive: deep-audit fix-round 3, 2026-09-20 -- the quote-masker above
# still had no "#" comment awareness: an ordinary comment apostrophe
# ("# don'\''t skip this") before the real assertion opened an unterminated
# fake single-quote span (no closing "'" anywhere after it in the payload),
# masking the real closing brace away entirely -- live-confirmed to make
# check_helper_body() return None for both sides, silently allowing a real
# weakening payload. ---
out=$(payload_edit "$TESTFILE" 'check() {
  # don'\''t skip this
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  # don'\''t skip this
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after a comment apostrophe -> ask (was silently allowed by the old comment-unaware masker)" "$ok"

# --- Positive: GH #157 sibling (2026-09-21) -- an `echo \"` line before the
# real assertion: the escaped quote is a literal in bash, but the old masker
# opened an unterminated fake double-quote span at it, masking the closing
# brace away, same class as the comment-apostrophe case above. ---
out=$(payload_edit "$TESTFILE" 'check() {
  echo \" marker
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  echo \" marker
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after an escaped-quote line -> ask (was silently allowed by the old masker)" "$ok"

# --- Positive: GH #161 (2026-09-21) -- an `echo $'\''` line before the real
# assertion: ANSI-C quoting, one complete string in bash, but the old masker
# opened an unterminated fake single-quote span at the escaped apostrophe. ---
out=$(payload_edit "$TESTFILE" 'check() {
  echo $'"'"'\'"'"''"'"' marker
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  echo $'"'"'\'"'"''"'"' marker
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after an ANSI-C \$'\\'' line -> ask (was silently allowed by the old masker)" "$ok"

# --- Positive: deleting the final exit-gate line is invisible to a
# call-site diff, but it is the line that turns an accumulated fail count
# into the script's actual exit code -- this repo's own tests (including
# this gate's own) all use this idiom (deep-audit 2026-08-28). ---
out=$(payload_edit "$TESTFILE" '[ "$fail" -eq 0 ] && exit 0 || exit 1' 'echo done' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit deleting the [ \$fail -eq 0 ] exit-gate line -> ask" "$ok"

# --- Positive: two textually-identical assertion lines, one removed --
# set-based tracking collapsed both into one entry, so removing one of a
# pair was invisible (deep-audit 2026-08-28; fixed via Counter multisets). ---
out=$(payload_edit "$TESTFILE" 'check "dup" "$okd"
check "dup" "$okd"' 'check "dup" "$okd"' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit removing one of two identical assertion lines -> ask" "$ok"

# --- Negative: both identical assertion lines stay -> noask (proves the
# multiset fix does not over-fire on an unrelated same-count edit). ---
out=$(payload_edit "$TESTFILE" 'check "dup" "$okd"
check "dup" "$okd"' 'check "dup" "$okd"
check "dup" "$okd"' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit keeping both identical assertion lines -> noask" "$ok"

# --- Positive: relocating an assertion into an inert HEREDOC body leaves
# the line text present but never executed (deep-audit 2026-08-28). ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' "cat <<'MARK'
check \"case two\" \"\$ok2\"
MARK" | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit relocating an assertion into a HEREDOC body -> ask" "$ok"

# --- Positive: relocating an assertion into a ": '...'" colon no-op block
# (bash's inert-multiline-comment idiom) has the identical effect (deep-
# audit 2026-08-28). ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' ": '
check \"case two\" \"\$ok2\"
'" | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit relocating an assertion into a ': ...' no-op block -> ask" "$ok"

# --- Positive: 2026-09-21 deep-audit -- ")" was missing from the shared
# masker's word-boundary set, so "(true)#don't skip" did not open a comment
# and its apostrophe masked the real closing brace away, same class as the
# fix-round 3 case above. ---
out=$(payload_edit "$TESTFILE" 'check() {
  (true)#don'\''t skip
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' 'check() {
  (true)#don'\''t skip
  pass=$((pass + 1))
}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "Edit weakening real logic after a ')#' comment apostrophe -> ask (was silently allowed)" "$ok"

# --- Positive: 2026-09-21 deep-audit -- FUNC_OPEN_RE only matched a
# line-start `check() {`. Real bash also honors `function check {` (no
# parens), `check() ( ... )` (subshell body) and a mid-line `true; check() {`,
# so a shadowing no-op in any of those three spellings was invisible to the
# last-definition-wins scan. Same shape as the shadowing test above: the
# real definition stays byte-identical, new_string appends the shadow. ---
for shadow in 'function check {
  pass=$((pass + 1))
}' 'check() (
  pass=$((pass + 1))
)' 'true; check() {
  pass=$((pass + 1))
}'; do
  out=$(payload_edit "$TESTFILE" 'check() {
  [ "$2" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
}' "check() {
  [ \"\$2\" = 0 ] && pass=\$((pass + 1)) || fail=\$((fail + 1))
}
$shadow" | bash "$GATE" 2>/dev/null)
  ok=1; is_ask "$out" && ok=0
  check "Edit appending a shadowing no-op check def spelled '${shadow%%$'\n'*}' -> ask (was silently missed)" "$ok"
done

# --- Negative: only adding a new assertion -> noask ---
out=$(payload_edit "$TESTFILE" 'check "case two" "$ok2"' 'check "case two" "$ok2"
check "case three" "$ok3"' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit only adding an assertion -> noask" "$ok"

# --- Negative: new-file test creation -> noask (no old side to weaken) ---
NEWFILE="$WORK/tests/hooks/test-brandnew.sh"
out=$(payload_write "$NEWFILE" 'check "new case" "$ok"' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Write to a brand-new test file -> noask" "$ok"

# --- Negative: non-test path containing "test"/"spec" as a substring -> noask ---
out=$(payload_edit "$WORK/skills/review/test-coverage/SKILL.md" 'assert nothing here' '' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" || ok=0
check "Edit to a path merely containing 'test' as a substring -> noask" "$ok"

# --- the bash fast path (_silent_fastpath.sh) must defer every payload python could ask on ---
# A non-string file_path makes PATH_RE.search raise, which asks, though no "test" is in the text.
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":true,"old_string":"a","new_string":"b"}}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "file_path true (non-string, no test/spec text) -> ask" "$ok"

# A raw NUL makes the JSON invalid, which asks; bash must not strip it into a valid payload.
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.py","old_string":"a\000","new_string":"b"}}' | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "raw NUL byte inside a string (invalid JSON) -> ask" "$ok"

# A \u escape can spell the test path without the raw text containing "test".
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/\\u0074ests/x.sh","old_string":"check \\"one\\" \\"$ok\\"","new_string":""}}' "$WORK" | bash "$GATE" 2>/dev/null)
ok=1; is_ask "$out" && ok=0
check "\\u-escaped tests/ path removing a check() -> ask" "$ok"

out=$(payload_edit "$WORK/src/app.py" 'x = 1' 'x = 2' | bash "$GATE" 2>&1); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "ordinary Edit to a non-test path -> exit 0, no output, no stderr" "$ok"


echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
