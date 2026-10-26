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
  bad "shfmt not found on PATH, so this lint cannot run (macOS: brew install shfmt; Linux: pip install shfmt-py, not Ubuntu's apt package)"
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
# scan FILE: the scanner's stdout; its rc lands in the caller's $?.
scan() { python3 -I "$SCAN" "$1" 2>"$probe/err"; }
hit_lines() { /usr/bin/grep -v '^EXEMPT ' | sed -n 's/^[^:]*:\([0-9]*\):.*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }

# One race per statement (line numbers in want_lines), each a shape a past check missed.
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
echo "$o" | grep -E -q 'y'
printf '%s|%s\n' a "$b" | grep -q a
x \
  | grep -iq y
v=`x | grep -q y`
out | if grep -q x; then :; fi
out | while grep -q x; do :; done
out | until grep -q x; do :; done
out | time grep -q y
out | { a || grep -q y; }
out | case $v in p) grep -q x;; esac
out | for i in 1; do grep -q x; done
x | sudo -iu bob grep -q y
x | nohup grep -q y
x | env "$V=1" grep -q y
x | env -S 'grep -q' y
x | grep --qui y
echo "pipe-into-grep-q: deliberate" | grep -q x
x | grep -q y 0<&0
x | env -S 'FOO=1 grep -q' y
x | env -iS 'grep -q' y
x | sudo FOO=1 grep -q y
x | v=$(grep -q y)
x | echo "$(grep -q y && echo ok)"
x | diff <(grep -q y) f
x | while read -r f; do grep -q pat; done
x | while read -r f; do grep -q pat -; done
x | for f in $(grep -q y); do :; done
x | case $(grep -q y) in a) ;; esac
x | cat < <(grep -q y)
x | timeout --sig KILL 5 grep -q y
x | env --split 'grep -q' y
x | while read f; do grep -q pat /dev/stdin; done
x | while read l; do grep -q -f - file; done
x | grep -q y <&"$fd"
x | { echo "$(grep -q y)" < f; }
x | for ((i=0; i<$(grep -q y; echo 1); i++)); do :; done
x | while read f; do grep -q -e pat -f /dev/stdin file; done
x | cat <<<"$(grep -q z)" < f
x | local v=$(grep -q y) < "$f"
x | v=$(grep -q y) < "$f"
x | [[ $(grep -q y) ]]
x | while read f; do grep -q pat /dev/fd/0; done
x | cat > >(grep -q y) < "$f"
x | cat < "$f" > >(grep -q y)
x | tee >(grep -q y) >/dev/null
x | { tee >(grep -q y) >/dev/null; } < "$f"
x | while read -r l; do cat "$l" > >(grep -q y); done < "$f"
x | ( cat big > >(grep -q y) ) < "$f"
x | while read l; do grep -q pat /proc/self/fd/0; done
tee >(grep -q y) < "$f" | cat
tee >(grep -q y) < "$f"
f() { cat "$1" > >(grep -q y); }
EOF
want_lines="1 2 3 4 5 6 7 8 9 10 12 14 15 16 17 18 19 20 22 26 27 28 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79"
n_want=$(wc -w <<<"$want_lines" | tr -d ' ')
out=$(scan "$probe/bad.sh"); rc=$?
got_lines=$(hit_lines <<<"$out")
[ "$rc" -eq 1 ] && [ "$got_lines" = "$want_lines" ] \
  && ok "probe: all $n_want planted races found on their own lines (wrappers, groups, if/while/case/for/time, redirects, backticks, heredoc code, >(...) anywhere)" \
  || bad "probe: rc $rc, lines [$got_lines], want rc 1 and [$want_lines]; stderr: $(cat "$probe/err")"

cat > "$probe/good.sh" <<'EOF'
# printf "$r" | grep -q x
grep -q x <<<"$OUT"
grep -q x <<<"$(stat --version)"
echo "$OUT" | grep -c x
[ "$(printf '%s\n' "$ids" | grep -c .)" -eq 2 ]
a || grep -q x "$f"
grep -q x "$f" | head -1
x | grep -c " -eq " "$f"
grep -c x "$f" # a | grep -q b
echo "a | grep -q b"
x | grep -e -q "$f"
x | grep --regexp -q "$f"
x | grep --regexp=-q "$f"
echo $((a|b)) | grep -c x
case "$x" in a|grep) grep -q y "$f" ;; esac
cat <<'DOC'
printf x | grep -q y
DOC
x | { grep -q y <<<"$z"; }
x | grep -q y < "$f"
x | env FOO=1 sed -n p
x | grep --reg -q y
x | grep -q y <&3
x | while read -r f; do grep -q pat "$f"; done
x | for f in a b; do grep -q -e pat "$f"; done
x | while read f; do grep -rq pat; done
x | while read l; do v=$(grep -q y); done < "$f"
x | grep --col=never -c y
x | for f in $(grep -q y); do :; done < "$f"
x | case $(grep -q y) in a) ;; esac < "$f"
x | grep -q y < "$f" <<<"$(grep -q z)"
tee >(grep -c y) < "$f"
tee >(while read -r l; do grep -q y "$l"; done) < "$f"
x | [[ $(grep -q y) ]] < "$f"
x | (( $(grep -q y; echo 1) )) < "$f"
EOF
out=$(scan "$probe/good.sh"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "probe: comments, quoted text, here-strings, grep -c, -e/--regexp/--reg -q, \$((a|b)), case patterns, quoted heredocs, own-stdin redirects, loop greps on files or -r, a loop with its own stdin, --col, substitutions after a stdin redirect or in a redirected [[ ]]/(( )) are clean" \
  || bad "probe: rc $rc on the race-free file: $out $(cat "$probe/err")"

# The exemption counts only as a trailing comment, and is reported, not hidden.
printf 'x | grep -q y  # pipe-into-grep-q: deliberate\n' > "$probe/exempt.sh"
out=$(scan "$probe/exempt.sh"); rc=$?
[ "$rc" -eq 0 ] && /usr/bin/grep -q '^EXEMPT ' <<<"$out" && ok "probe: a trailing deliberate marker exempts the hit and reports it as EXEMPT" \
  || bad "probe: the trailing marker gave rc $rc: $out"

printf 'if x; then\n' > "$probe/unparsable.sh"
printf 'x | grep -q y\n' > "$probe/race.sh"
out=$(python3 -I "$SCAN" "$probe/unparsable.sh" "$probe/race.sh" 2>"$probe/err"); rc=$?
[ "$rc" -eq 2 ] && [ -s "$probe/err" ] && /usr/bin/grep -q 'race.sh:1:' <<<"$out" \
  && ok "probe: an unparsable file is an error (rc 2), and hits in the other files are still printed" \
  || bad "probe: unparsable + race gave rc $rc, out [$out], want rc 2 with race.sh:1 listed"
out=$(scan "$probe/missing.sh"); rc=$?
[ "$rc" -eq 2 ] && ok "probe: an unreadable file is an error (rc 2), never clean" \
  || bad "probe: an unreadable file gave rc $rc, want 2"

# The scanner checks its shfmt first: shfmt 3.4 rejects --to-json, and its -tojson encodes operators
# as numbers, which once made every file scan clean. Both must be an error, never a clean pass.
real_shfmt=$(command -v shfmt)
mkdir -p "$probe/old" "$probe/numeric"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --to-json ] && { echo "flag provided but not defined: -to-json" >&2; exit 2; }; done\nexec "%s" "$@"\n' "$real_shfmt" > "$probe/old/shfmt"
# numeric rewrites the parsed tree (any JSON spacing): every "Op": "|" becomes 12, as 3.4 encodes it.
cat > "$probe/numeric/fix.py" <<'PY'
import json, sys
def fix(n):
    if isinstance(n, dict):
        return {k: (12 if k == 'Op' and v == '|' else fix(v)) for k, v in n.items()}
    return [fix(v) for v in n] if isinstance(n, list) else n
json.dump(fix(json.load(sys.stdin)), sys.stdout)
PY
printf '#!/bin/sh\n"%s" "$@" | python3 -I "%s"\n' "$real_shfmt" "$probe/numeric/fix.py" > "$probe/numeric/shfmt"
mkdir -p "$probe/nonjson"
printf '#!/bin/sh\necho "shfmt wrapper banner"\n' > "$probe/nonjson/shfmt"
chmod +x "$probe/old/shfmt" "$probe/numeric/shfmt" "$probe/nonjson/shfmt"
for kind in old numeric nonjson; do
  out=$(PATH="$probe/$kind:$PATH" python3 -I "$SCAN" "$probe/race.sh" 2>"$probe/err"); rc=$?
  [ "$rc" -eq 2 ] && /usr/bin/grep -q 'shfmt >= 3.5 is needed' "$probe/err" \
    && ok "probe: a shfmt whose tree the scanner cannot read ($kind) is an error (rc 2), never clean" \
    || bad "probe: $kind shfmt gave rc $rc, want 2 naming shfmt >= 3.5: $out $(cat "$probe/err")"
done

# The audit's known-bad fixtures are invalid shell on purpose (run-gauntlet.sh's lintable() and
# pre-commit's staged_lint() exclude the same path).
files=()
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] && files+=("$ROOT/$rel")
done < <(cd "$ROOT" && git ls-files '*.sh' 'git-hooks/*' ':(exclude)tests/skills/harness-audit/known-bad')

out=$(python3 -I "$SCAN" "${files[@]}" 2>"$probe/err"); rc=$?
[ "$rc" -le 2 ] || bad "the scanner crashed (rc $rc): $(cat "$probe/err")"
found=$(/usr/bin/grep -v '^EXEMPT ' <<<"$out")
if [ -n "$found" ]; then
  while IFS= read -r h; do
    bad "${h#"$ROOT"/} -- use grep -q PAT <<<\"\$x\" or <<<\"\$(cmd)\""
  done <<<"$found"
fi
[ "$rc" -eq 2 ] && bad "the scanner could not check every file: $(cat "$probe/err")"
[ "$rc" -eq 0 ] && ok "no tracked shell file pipes into grep -q (${#files[@]} files parsed)"
[ "$rc" -le 1 ] && [ -s "$probe/err" ] && bad "the scanner wrote to stderr: $(cat "$probe/err")"
# A ratchet on exemptions: only this file's race probe may carry the marker.
exempt=$(/usr/bin/grep -c '^EXEMPT ' <<<"$out")
[ "$exempt" -le 1 ] && ok "deliberate exemptions: $exempt (allowed 1, the race probe above)" \
  || bad "$exempt deliberate exemptions, allowed 1: $(/usr/bin/grep '^EXEMPT ' <<<"$out" | tr '\n' ' ')"
[ "${#files[@]}" -ge 100 ] && ok "lint saw ${#files[@]} shell files (not vacuous)" \
  || bad "lint saw only ${#files[@]} shell files; the file listing no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
