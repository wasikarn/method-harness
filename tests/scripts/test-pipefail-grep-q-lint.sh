#!/usr/bin/env bash
# test-pipefail-grep-q-lint.sh — under `set -o pipefail`, `writer | grep -q PAT` is a race, not a
# check. grep -q exits on its first match; a writer still writing then dies of SIGPIPE (141) and
# pipefail turns the match into a failure. bash builtins write line by line (stdout is
# line-buffered); other commands write once per buffer (~4 KiB), so it fires on multi-line builtin
# output or big command output. It flaked test-run-gauntlet-wiring.sh in 2 of 4 gauntlet runs on
# 2026-10-23 ("hook_test_files() does NOT list: <a listed file>") and rows in test-fragments-arm.sh
# and others, only under the gauntlet's parallel load. Race-free forms: `grep -q PAT <<<"$x"`,
# `grep -q PAT <<<"$(cmd)"` (bash holds the whole output before grep runs), or `case`.
#
# The check is tests/_lib/pipe_into_grep_q.py over shfmt's syntax tree: line regexes and then a
# hand-written lexer each missed sites in review (GH #578, #597, #598). Every tracked shell file is
# checked, pipefail or not: a file without its own `set -o pipefail` can be sourced under one
# (harness-audit's checks/*.sh). The scanner exits 2 on any error (shfmt missing, a file it cannot
# read or parse), and anything but exit 0 fails here: an error is never a clean result.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SCAN="$ROOT/tests/_lib/pipe_into_grep_q.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== nothing pipes into grep -q (pipefail turns its early exit into a failure) ==="

if ! command -v shfmt >/dev/null 2>&1; then
  bad "shfmt not found on PATH, so this lint cannot run (macOS: brew install shfmt; Linux: apt install shfmt or pip install shfmt-py)"
  echo "=== Summary: $pass passed, $fail failed ==="
  exit 1
fi

# The race itself, made deterministic: the writer emits the match, then keeps writing builtin lines
# (bounded) past any pipe buffer, so it always outlives grep -q and meets a closed pipe. One big
# printf does not: it can finish before grep exits. A parent that ignores SIGPIPE (trap -p shows
# it, and it cannot be reset) turns the write error into rc 0, so the race cannot fire there.
(set -o pipefail; { printf 'needle\n'; i=0; while [ "$i" -lt 1000000 ]; do printf 'hay\n' || break; i=$((i + 1)); done; } \
  | /usr/bin/grep -qxF needle) 2>/dev/null  # pipe-into-grep-q: deliberate
rc=$?
if [ -n "$(trap -p PIPE)" ]; then
  ok "probe: SIGPIPE is ignored in this shell, so the race cannot fire here (rc $rc)"
elif [ "$rc" -eq 141 ]; then
  ok "probe: piped grep -q under pipefail fails on a present line (rc 141, SIGPIPE)"
else
  bad "probe: piped grep -q returned rc $rc, not 141; the race this lint exists for no longer reproduces"
fi
(set -o pipefail; /usr/bin/grep -qxF needle <<<$'hay\nneedle\nhay') && ok "probe: the here-string form finds the same line" || bad "probe: the here-string form missed the line"

probe=$(mktemp -d)
[ -n "$probe" ] && [ -d "$probe" ] || { echo "  FAIL: mktemp -d failed, probe rows cannot run" >&2; exit 1; }
trap '[ -n "$probe" ] && trash "$probe" 2>/dev/null; true' EXIT
# scan FILE: the scanner's hit lines, one per line; rc in $scan_rc.
scan() { python3 -I "$SCAN" "$1" 2>"$probe/err"; }

# One race per statement, each a shape a past check missed.
cat > "$probe/bad.sh" <<'EOF'
echo "$OUT" | grep -q x
printf "%s\n" "$r" | /usr/bin/grep -qxF "$f"
printf '%s' "$OUT" | tr -d '\n' | grep -qF 'Evil'
claude plugin test --help 2>&1 | grep --quiet "Run"
sed 's/#.*$//' "$f" | grep -e "$name" -q && n=1
v="$(grep -c x "$f" | grep -qv '^0$' && echo 1)"
printf '%s' "$OUT" | command grep -qE 'findings: [1-9]'
x | \grep -q y
x | egrep -q y
x |& grep --silent y
x |
  grep -q y
(( a << 2 ))
x | { grep -q y; }
x | grep 2>/dev/null -q y
x | env -u A LC_ALL=C grep -q y
x | timeout 5 grep -q y
x | grep "$(p)" -q
echo "`x | grep -q y`"
v=$(case $a in b) x | grep -q y;; esac)
cat <<DOC
$(x | grep -q y)
DOC
v=`a
b
x | grep -q y`
EOF
hits=$(scan "$probe/bad.sh"); scan_rc=$?
want_lines="1 2 3 4 5 6 7 8 9 10 12 14 15 16 17 18 19 20 22 26"
got_lines=$(printf '%s\n' "$hits" | sed -n 's/^[^:]*:\([0-9]*\):.*/\1/p' | tr '\n' ' ' | sed 's/ $//')
[ "$scan_rc" -eq 1 ] && [ "$got_lines" = "$want_lines" ] \
  && ok "probe: all 21 planted races found on their own lines (wrappers, groups, redirects, \$(...) in words, backticks in quotes, heredoc code)" \
  || bad "probe: rc $scan_rc, lines [$got_lines], want rc 1 and [$want_lines]; stderr: $(cat "$probe/err")"

cat > "$probe/good.sh" <<'EOF'
# printf "$r" | grep -q x
grep -q x <<<"$OUT"
grep -q x <<<"$(stat --version)"
echo "$OUT" | grep -c x
[ "$(printf '%s\n' "$ids" | grep -c .)" -eq 2 ]
a || grep -q x "$f"
x | grep -c " -eq " "$f"
grep -c x "$f" # a | grep -q b
echo "a | grep -q b"
x | grep -e -q "$f"
echo $((a|b)) | grep -c x
cat <<'DOC'
printf x | grep -q y
DOC
x | grep -q y  # pipe-into-grep-q: deliberate
EOF
hits=$(scan "$probe/good.sh"); scan_rc=$?
[ "$scan_rc" -eq 0 ] && [ -z "$hits" ] \
  && ok "probe: comments, quoted text, here-strings, grep -c, -e -q, \$((a|b)), quoted heredoc bodies, the deliberate marker are clean" \
  || bad "probe: rc $scan_rc on the race-free file: $hits $(cat "$probe/err")"

printf 'if x; then\n' > "$probe/unparsable.sh"
hits=$(scan "$probe/unparsable.sh"); scan_rc=$?
[ "$scan_rc" -eq 2 ] && [ -s "$probe/err" ] && ok "probe: an unparsable file is an error (rc 2), never clean" \
  || bad "probe: an unparsable file gave rc $scan_rc, want 2"
hits=$(scan "$probe/missing.sh"); scan_rc=$?
[ "$scan_rc" -eq 2 ] && ok "probe: an unreadable file is an error (rc 2), never clean" \
  || bad "probe: an unreadable file gave rc $scan_rc, want 2"

# The audit's known-bad fixtures are invalid shell on purpose (same exclusion as the lint layer).
files=()
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] && files+=("$ROOT/$rel")
done < <(cd "$ROOT" && git ls-files '*.sh' 'git-hooks/*' ':(exclude)tests/skills/harness-audit/known-bad')

found=$(python3 -I "$SCAN" "${files[@]}" 2>"$probe/err"); scan_rc=$?
case "$scan_rc" in
  0) ok "no tracked shell file pipes into grep -q (${#files[@]} files parsed)" ;;
  1) while IFS= read -r h; do
       bad "${h#"$ROOT"/} -- use grep -q PAT <<<\"\$x\" or <<<\"\$(cmd)\""
     done <<<"$found" ;;
  *) bad "the scanner failed (rc $scan_rc), so the tree was not checked: $(cat "$probe/err")" ;;
esac
[ -s "$probe/err" ] && [ "$scan_rc" -le 1 ] && bad "the scanner wrote to stderr: $(cat "$probe/err")"
[ "${#files[@]}" -ge 100 ] && ok "lint saw ${#files[@]} shell files (not vacuous)" \
  || bad "lint saw only ${#files[@]} shell files; the file listing no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
