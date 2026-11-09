#!/usr/bin/env bash
# test-citation-exists.sh -- tests for scripts/_lib/citation_exists.py, the report-only
# checker that says whether a cited path:line or commit SHA exists under given repo roots.
# Fixture tree: tests/scripts/fixtures/citation-exists (src/app.py has 3 lines, same.md twice).
# The symlink and the throwaway git repo are made at run time in a temp dir.
# Every assertion is against a HARDCODED expected label or count.
#
# Run standalone: bash tests/scripts/test-citation-exists.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init would then target the real repo (GH #234).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$ROOT/scripts/_lib/tmp-delete.sh"
SCRIPT="$ROOT/scripts/_lib/citation_exists.py"
FIX="$HERE/fixtures/citation-exists"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

T=$(mktemp -d)
cleanup() { [ -n "$T" ] && tmp_delete "$T"; return 0; }
trap cleanup EXIT

echo "=== citation_exists.py ==="
[ -f "$SCRIPT" ] || { bad "scripts/_lib/citation_exists.py missing"; echo "citation-exists: $pass passed, $fail failed"; exit 1; }

cp -R "$FIX" "$T/root"
printf 'secret\n' > "$T/outside.txt"
ln -s "$T/outside.txt" "$T/root/src/link.py"
git init -q "$T/repo"
git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
SHA=$(git -C "$T/repo" rev-parse HEAD)
printf 'src/removed.py\n' > "$T/diff-paths"

cat > "$T/input.md" <<EOF
resolved: src/app.py:2 and range src/app.py:1-3
past eof: src/app.py:9
absent file: src/gone.py:1
two basenames: same.md:1
unknown dir: nowhere/file.py:1
real sha $SHA
fake sha deadbeef1234567
deleted in diff: src/removed.py:4
symlink escape: src/link.py:1
traversal: ../outside.txt:1
versions 2.5:1 and 1.1.591 are not citations
one basename: app.py:3
EOF

python3 "$SCRIPT" --json --root "$T/root" --root "$T/repo" --diff-paths "$T/diff-paths" "$T/input.md" > "$T/out.json"
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 on a normal run" || bad "exit $rc on a normal run"

check() { # $1 = input line, $2 = citation substring, $3 = expected label
  local got
  got=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(",".join(i["label"] for i in d["items"] if i["line"] == int(sys.argv[2]) and sys.argv[3] in i["citation"]))
' "$T/out.json" "$1" "$2")
  [ "$got" = "$3" ] && ok "line $1 $2 -> $3" || bad "line $1 $2 -> '$got', want '$3'"
}
check 1 "src/app.py:2" resolved
check 1 "src/app.py:1-3" resolved
check 2 "src/app.py:9" missing
check 3 "src/gone.py" missing
check 4 "same.md" ambiguous-or-outside
check 5 "nowhere/file.py" ambiguous-or-outside
check 6 "$SHA" resolved
check 7 "deadbeef1234567" ambiguous-or-outside
check 8 "src/removed.py" resolved
check 9 "src/link.py" ambiguous-or-outside
check 10 "../outside.txt" ambiguous-or-outside
check 11 "" ""
check 12 "app.py:3" resolved

totals=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
c = d["counts"]
print(d["resolved"], d["total"], c["resolved"], c["missing"], c["ambiguous-or-outside"])
' "$T/out.json")
[ "$totals" = "5 12 5 2 5" ] && ok "totals 5 of 12 (5/2/5)" || bad "totals '$totals', want '5 12 5 2 5'"

# Text report: header, never the word "verified".
txt=$(python3 "$SCRIPT" --root "$T/root" --root "$T/repo" --diff-paths "$T/diff-paths" < "$T/input.md")
case "$txt" in "citations exist: 5 of 12 resolved"*) ok "text header" ;; *) bad "text header: ${txt%%$'\n'*}" ;; esac
/usr/bin/grep -qi verified <<<"$txt" && bad "text output says 'verified'" || ok "text output never says 'verified'"
/usr/bin/grep -q "missing.*line 2" <<<"$txt" && ok "text lists a missing item with its line" || bad "text lacks 'missing ... line 2'"

# Empty input.
empty=$(printf '' | python3 "$SCRIPT" --root "$T/root")
rc=$?
[ "$rc" -eq 0 ] && [ "${empty%%$'\n'*}" = "citations exist: 0 of 0 resolved" ] && ok "empty input -> 0 of 0, exit 0" || bad "empty input rc=$rc: $empty"

# Usage errors exit 2.
python3 "$SCRIPT" "$T/input.md" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no --root -> exit 2" || bad "no --root -> exit $rc"
python3 "$SCRIPT" --root "$T/root" "$T/does-not-exist" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unreadable input -> exit 2" || bad "unreadable input -> exit $rc"

# Round-1 validator findings: each case is red on the first version of the script.
label_of() { # $1 = input text, extra args = more script flags; prints the labels, comma-joined
  local text=$1; shift
  printf '%s\n' "$text" | python3 "$SCRIPT" --json --root "$T/root" "$@" 2>/dev/null |
    python3 -c 'import json,sys; print(",".join(i["label"] for i in json.load(sys.stdin)["items"]))'
}
[ "$(label_of 'src/app.py:9-2')" = "missing" ] && ok "reversed range past EOF -> missing" || bad "reversed range -> '$(label_of 'src/app.py:9-2')'"
[ "$(label_of 'src/app.py:5-6')" = "missing" ] && ok "range starting past EOF -> missing" || bad "range past EOF start"
[ "$(label_of 'src/app.py:0-2')" = "missing" ] && ok "range starting at 0 -> missing" || bad "range starting at 0"
[ "$(label_of 'src/app.py:2-3')" = "resolved" ] && ok "in-range range -> resolved" || bad "in-range range"
printf 'x\n' > "$T/root/src/locked.py"; chmod 000 "$T/root/src/locked.py"
if [ -r "$T/root/src/locked.py" ]; then
  echo "  SKIP: unreadable cited file (running as root, chmod 000 does not hide it)"
else
  lk=$(label_of 'src/locked.py:1')
  [ "$lk" = "ambiguous-or-outside" ] && ok "unreadable cited file -> ambiguous-or-outside, no traceback" || bad "unreadable file -> '$lk'"
fi
chmod 644 "$T/root/src/locked.py"
printf '\377\376\n' > "$T/diff.bin"
printf 'src/app.py:1\n' | python3 "$SCRIPT" --root "$T/root" --diff-paths "$T/diff.bin" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "non-UTF-8 --diff-paths -> exit 2" || bad "non-UTF-8 --diff-paths -> exit $rc"
printf '../../etc/passwd\n' > "$T/diff-trav"
[ "$(label_of '../../etc/passwd:99999' --diff-paths "$T/diff-trav")" = "ambiguous-or-outside" ] && ok "traversal in --diff-paths still outside" || bad "traversal in --diff-paths resolved"
[ -z "$(label_of 'C:\repo\src\app.py:2')" ] && ok "Windows-style path is not a citation" || bad "Windows-style path got a label"
python3 -c "print('a.'*20000)" > "$T/long.md"
s=$(date +%s); timeout 20 python3 "$SCRIPT" --root "$T/root" "$T/long.md" > /dev/null; rc=$?; e=$(date +%s)
[ "$rc" -eq 0 ] && [ $((e - s)) -lt 5 ] && ok "20000-char token finishes under 5 s" || bad "long token rc=$rc, $((e - s)) s"

# Round-2 review findings (spec and standards): red on the round-1 script.
printf 'src/app.py\nsrc/removed.py\n' > "$T/diff-names"
[ "$(label_of 'src/app.py:999' --diff-paths "$T/diff-names")" = "missing" ] && ok "diff list does not skip the line check of a file still on disk" || bad "diff-listed existing file past EOF -> '$(label_of 'src/app.py:999' --diff-paths "$T/diff-names")'"
printf 'setup.py\n' > "$T/diff-root"
[ "$(label_of 'setup.py:3' --diff-paths "$T/diff-root")" = "resolved" ] && ok "deleted root-level file in the diff list -> resolved" || bad "root-level deleted file -> '$(label_of 'setup.py:3' --diff-paths "$T/diff-root")'"
[ "$(label_of 'setup.py:3')" = "ambiguous-or-outside" ] && ok "same bare name with no diff list -> ambiguous-or-outside" || bad "bare name without diff list"
[ "$(label_of 'src/removed.py:7' --diff-paths "$T/diff-names")" = "resolved" ] && ok "diff-listed file gone from the tree -> resolved" || bad "diff-listed deleted file"
printf 'src/app.py:1\n' | python3 "$SCRIPT" --root "$T/root" --root "$T/nope" > "$T/stale.out" 2> "$T/stale.err"; rc=$?
[ "$rc" -eq 0 ] && /usr/bin/grep -q "citations exist: 1 of 1" "$T/stale.out" && /usr/bin/grep -q "nope" "$T/stale.err" && ok "a stale --root warns and is skipped" || bad "stale --root rc=$rc"
printf 'src/app.py:1\n' | python3 "$SCRIPT" --root "$T/nope" > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no usable --root -> exit 2" || bad "no usable --root -> exit $rc"

# Audit findings on PRs 975 to 978 (deep-audit, Codex checker): red on the merged script.
# 1. deep-audit feeds check-verdict.py's JSON; an escaped newline put a backslash in front of the next cite.
python3 - "$T/verdict.json" <<'PY'
import json, sys
verdict = {"contract_version": 1, "pass": True, "findings": [], "scope_ok": True, "unexpected_files": [],
           "checked": [{"claim": "c", "evidence": "src/app.py:1\nsrc/nope.py:999\tsrc/app.py:3"}]}
json.dump(verdict, open(sys.argv[1], "w"), indent=2)
PY
python3 "$SCRIPT" --root "$T/root" "$T/verdict.json" > "$T/v.out" 2>&1
/usr/bin/grep -q "citations exist: 2 of 3 resolved" "$T/v.out" && /usr/bin/grep -q "missing: 1" "$T/v.out" && ok "JSON verdict: a cite after an escaped newline or tab is still checked" || bad "JSON verdict with escaped newline: $(head -3 "$T/v.out" | tr '\n' ' ')"
python3 "$SCRIPT" --root "$T/root" < "$T/verdict.json" > "$T/v2.out" 2>&1
/usr/bin/grep -q "citations exist: 2 of 3 resolved" "$T/v2.out" && ok "the same JSON verdict on stdin" || bad "JSON verdict on stdin: $(head -1 "$T/v2.out")"
printf '["src/app.py:1", "not a cite 1.1.591"]\n' > "$T/list.json"
python3 "$SCRIPT" --root "$T/root" "$T/list.json" > "$T/v3.out" 2>&1
/usr/bin/grep -q "citations exist: 1 of 1 resolved" "$T/v3.out" && ok "a JSON array of strings is read too" || bad "JSON array: $(head -1 "$T/v3.out")"
# 2. A huge line number is a cite past the end of any file, not a crash (exit 0 whenever it ran).
python3 -c "print('src/app.py:' + '9' * 5000); print('src/app.py:1-' + '9' * 5000)" > "$T/bigline.md"
python3 "$SCRIPT" --root "$T/root" "$T/bigline.md" > "$T/big.out" 2> "$T/big.err"; rc=$?
[ "$rc" -eq 0 ] && /usr/bin/grep -q "missing: 2" "$T/big.out" && [ ! -s "$T/big.err" ] && ok "5000-digit line numbers -> missing, exit 0, no traceback" || bad "huge line number rc=$rc: $(tail -1 "$T/big.err")"
# 3. The SHA-versus-path-cite overlap check stays linear.
python3 -c "print('src/app.py:1 ' * 16000 + 'deadbeef1234567 ' * 16000)" > "$T/many.md"
s=$(date +%s); timeout 30 python3 "$SCRIPT" --root "$T/root" "$T/many.md" > /dev/null; rc=$?; e=$(date +%s)
[ "$rc" -eq 0 ] && [ $((e - s)) -lt 5 ] && ok "32000 cites on one line finish under 5 s" || bad "many cites rc=$rc, $((e - s)) s"

# Round 2 of the same audit (whole-picture hunter and the Codex re-check): red on the first fix commit.
# `line` for JSON input is the index of the string value, even when a string holds newlines.
printf '["one\\ntwo", "src/gone.py:4"]\n' > "$T/lines.json"
python3 "$SCRIPT" --root "$T/root" "$T/lines.json" > "$T/l.out" 2>&1
/usr/bin/grep -q "src/gone.py:4  (line 2)" "$T/l.out" && ok "JSON input: line is the string's index, not a physical line" || bad "JSON line number: $(tail -1 "$T/l.out")"
# A double-escaped newline (a literal backslash and n inside the decoded string) must not hide the next cite.
python3 - "$T/double.json" <<'PY'
import json, sys
json.dump({"checked": [{"claim": "c", "evidence": "src/app.py:1\\nsrc/nope.py:999\\tsrc/app.py:3"}]}, open(sys.argv[1], "w"))
PY
python3 "$SCRIPT" --root "$T/root" "$T/double.json" > "$T/d.out" 2>&1
/usr/bin/grep -q "citations exist: 2 of 3 resolved" "$T/d.out" && /usr/bin/grep -q "missing: 1" "$T/d.out" && ok "JSON input: a double-escaped newline or tab does not hide a cite" || bad "double-escaped newline: $(head -3 "$T/d.out" | tr '\n' ' ')"
# A Windows path inside JSON is still not a citation (the escape rule only follows a digit).
printf '["C:\\\\temp\\\\new.py:2"]\n' > "$T/win.json"
python3 "$SCRIPT" --root "$T/root" "$T/win.json" > "$T/w.out" 2>&1
/usr/bin/grep -q "citations exist: 0 of 0 resolved" "$T/w.out" && ok "JSON input: a Windows path is not a citation" || bad "Windows path in JSON: $(head -1 "$T/w.out")"
# A JSON number of thousands of digits must not make the parse fall back to raw text.
python3 -c "print('{\"n\": ' + '9' * 5000 + ', \"e\": \"src/app.py:1\\\\nsrc/nope.py:9\"}')" > "$T/bigint.json"
python3 "$SCRIPT" --root "$T/root" "$T/bigint.json" > "$T/b.out" 2>&1
/usr/bin/grep -q "citations exist: 1 of 2 resolved" "$T/b.out" && ok "JSON with a 5000-digit number is still decoded" || bad "big integer leaf: $(head -1 "$T/b.out")"
# A zero-padded line number is its value, not its digit count.
[ "$(label_of 'src/app.py:0000000001')" = "resolved" ] && ok "zero-padded line number -> resolved" || bad "zero-padded line number -> '$(label_of 'src/app.py:0000000001')'"

python3 "$SCRIPT" --selftest > /dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "--selftest passes" || bad "--selftest exit $rc"

echo "citation-exists: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
