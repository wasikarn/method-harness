#!/usr/bin/env bash
# test-pipefail-grep-q-lint.sh — under `set -o pipefail`, `printf '%s\n' "$x" | grep -q PAT` is a
# race, not a check. bash writes builtin output line by line (stdout is line-buffered), grep -q
# exits on its first match, and when it does so before printf's last write, printf dies of SIGPIPE
# (141) and pipefail turns a match into a failure. It flaked test-run-gauntlet-wiring.sh in 2 of 4
# gauntlet runs on 2026-10-23 ("hook_test_files() does NOT list: <a listed file>"), and the same
# shape failed rows in test-fragments-arm.sh and others, only under the gauntlet's parallel load.
# All 263 sites were converted on 2026-10-24. Race-free forms: `case "$x" in *PAT*)`,
# `grep -q PAT <<<"$x"` (bash writes the here-string before grep runs), or grep without -q.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

# The shape: echo/printf piped straight into grep with a -q flag, on a non-comment line.
SHAPE='(^|[^[:alnum:]_])(printf|echo)([[:space:]][^|]*)?\|[[:space:]]*(/usr/bin/)?grep[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*-[[:alpha:]]*q'
count() { /usr/bin/grep -vE '^[[:space:]]*#' "$1" | /usr/bin/grep -cE "$SHAPE"; }

echo "=== no new printf/echo | grep -q under pipefail ==="

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
printf '%s\n' 'echo "$OUT" | grep -q x' 'printf "%s\n" "$r" | /usr/bin/grep -qxF "$f"' \
  "echo \"\$o\" | grep -E -q 'y'" > "$probe/bad.sh"
printf '%s\n' '# printf "$r" | grep -q x' 'grep -q x <<<"$OUT"' 'echo "$OUT" | grep -c x' \
  'my_echo | grep -q x' > "$probe/good.sh"
[ "$(count "$probe/bad.sh")" -eq 3 ] && ok "probe: all three planted shapes are counted" \
  || bad "probe: counted $(count "$probe/bad.sh") of 3 planted shapes"
[ "$(count "$probe/good.sh")" -eq 0 ] && ok "probe: comments, here-strings, grep -c, my_echo are not counted" \
  || bad "probe: counted $(count "$probe/good.sh") in the race-free file"
[ -n "$probe" ] && trash "$probe"

checked=0
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] || continue
  case "$rel" in tests/scripts/test-pipefail-grep-q-lint.sh) continue ;; esac
  /usr/bin/grep -q 'pipefail' "$ROOT/$rel" || continue
  checked=$((checked + 1))
  n=$(count "$ROOT/$rel")
  [ "$n" -eq 0 ] || bad "$rel: $n printf/echo | grep -q under pipefail; use grep -q PAT <<<\"\$x\" or case"
done < <(cd "$ROOT" && git ls-files '*.sh' 'git-hooks/*')

[ "$fail" -eq 0 ] && ok "no pipefail file pipes printf/echo into grep -q"
[ "$checked" -ge 20 ] && ok "lint saw $checked pipefail files (not vacuous)" \
  || bad "lint saw only $checked pipefail files; the file listing no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
