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
# The check is tests/_lib/pipe_into_grep_q.py, a small shell lexer: two line regexes before it
# missed sites (`| command grep -q` in hooks/session/memory-health-nudge.sh, continued lines) and
# flagged `-q` text inside quoted patterns. Every tracked shell file is checked, pipefail or not: a
# file without its own `set -o pipefail` can be sourced under one (harness-audit's checks/*.sh).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SCAN="$ROOT/tests/_lib/pipe_into_grep_q.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
count() { python3 -I "$SCAN" "$1" | wc -l | tr -d ' '; }

echo "=== nothing pipes into grep -q (pipefail turns its early exit into a failure) ==="

# The race itself, made deterministic: the writer emits the match, then keeps writing builtin lines
# (bounded) past any pipe buffer, so it always outlives grep -q and meets a closed pipe. One big
# printf does not: it can finish before grep exits. A parent that ignores SIGPIPE (trap -p shows
# it, and it cannot be reset) turns the write error into rc 0, so the race cannot fire there.
(set -o pipefail; { printf 'needle\n'; i=0; while [ "$i" -lt 1000000 ]; do printf 'hay\n' || break; i=$((i + 1)); done; } \
  | /usr/bin/grep -qxF needle) 2>/dev/null
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
# One race per line, each a shape a past check missed or should catch.
cat > "$probe/bad.sh" <<'EOF'
echo "$OUT" | grep -q x
printf "%s\n" "$r" | /usr/bin/grep -qxF "$f"
echo "$o" | grep -E -q 'y'
printf '%s' "$OUT" | tr -d '\n' | grep -qF 'Evil'
claude plugin test --help 2>&1 | grep --quiet "Run"
sed 's/#.*$//' "$f" | grep -e "$name" -q && n=1
printf '%s|%s\n' a "$b" | grep -q a
v="$(grep -c x "$f" | grep -qv '^0$' && echo 1)"
printf '%s' "$OUT" | command grep -qE 'findings: [1-9]'
x | \grep -q y
x | egrep -q y
x | env LC_ALL=C grep -q y
x |& grep --silent y
x |
  grep -q y
x \
  | grep -iq y
v=`x | grep -q y`
EOF
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
echo $((a|b)) | grep -c x
case "$x" in a|grep) grep -q y "$f" ;; esac
cat <<'DOC'
printf x | grep -q y
DOC
EOF
n_bad=$(count "$probe/bad.sh"); n_good=$(count "$probe/good.sh")
[ "$n_bad" -eq 16 ] && ok "probe: all 16 planted races are found (command/\\/egrep/env grep, |&, continued pipes, \$(...), backticks)" \
  || bad "probe: found $n_bad of 16 planted races: $(python3 -I "$SCAN" "$probe/bad.sh" | tr '\n' ' ')"
[ "$n_good" -eq 0 ] && ok "probe: comments, quoted -q and |, here-strings, grep -c, -e -q, \$((a|b)), case, heredoc bodies are not counted" \
  || bad "probe: counted $n_good in the race-free file: $(python3 -I "$SCAN" "$probe/good.sh" | tr '\n' ' ')"

files=()
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] || continue
  case "$rel" in tests/scripts/test-pipefail-grep-q-lint.sh) continue ;; esac
  files+=("$ROOT/$rel")
done < <(cd "$ROOT" && git ls-files '*.sh' 'git-hooks/*')

found=$(python3 -I "$SCAN" "${files[@]}")
if [ -z "$found" ]; then
  ok "no tracked shell file pipes into grep -q"
else
  while IFS= read -r h; do
    bad "${h#"$ROOT"/} -- use grep -q PAT <<<\"\$x\" or <<<\"\$(cmd)\""
  done <<<"$found"
fi
[ "${#files[@]}" -ge 100 ] && ok "lint saw ${#files[@]} shell files (not vacuous)" \
  || bad "lint saw only ${#files[@]} shell files; the file listing no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
