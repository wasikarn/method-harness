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
# Every tracked shell file is linted, pipefail or not: a file without its own `set -o pipefail` can
# be sourced under one (harness-audit's checks/*.sh run inside audit.sh's `set -euo pipefail`).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

# The shape: a single `|` (not `||`) into grep, with -q, --quiet or --silent among grep's own words
# (they end at | ; & or `)`), on a non-comment line. Any writer counts, multi-stage pipes included,
# and a `|` inside the writer's arguments does not hide the grep.
SHAPE='(^|[^|])\|[[:space:]]*(/usr/bin/)?grep([[:space:]]+[^|;&)]*)?[[:space:]](-[[:alpha:]]*q[[:alpha:]]*|--quiet|--silent)([[:space:]]|$)'
count() { /usr/bin/grep -vE '^[[:space:]]*#' "$1" | /usr/bin/grep -cE "$SHAPE"; }

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
cat > "$probe/bad.sh" <<'EOF'
echo "$OUT" | grep -q x
printf "%s\n" "$r" | /usr/bin/grep -qxF "$f"
echo "$o" | grep -E -q 'y'
printf '%s' "$OUT" | tr -d '\n' | grep -qF 'Evil'
claude plugin test --help 2>&1 | grep --quiet "Run"
sed 's/#.*$//' "$f" | grep -e "$name" -q && n=1
printf '%s|%s\n' a "$b" | grep -q a
v="$(grep -c x "$f" | grep -qv '^0$' && echo 1)"
EOF
cat > "$probe/good.sh" <<'EOF'
# printf "$r" | grep -q x
grep -q x <<<"$OUT"
grep -q x <<<"$(stat --version)"
echo "$OUT" | grep -c x
[ "$(printf '%s\n' "$ids" | grep -c .)" -eq 2 ]
a || grep -q x "$f"
grep -q x "$f" | head -1
EOF
n_bad=$(count "$probe/bad.sh"); n_good=$(count "$probe/good.sh")
[ "$n_bad" -eq 8 ] && ok "probe: all 8 planted shapes are counted (multi-stage, --quiet, -e PAT -q, | in args)" \
  || bad "probe: counted $n_bad of 8 planted shapes"
[ "$n_good" -eq 0 ] && ok "probe: comments, here-strings, grep -c, ||, a later -eq are not counted" \
  || bad "probe: counted $n_good in the race-free file"

checked=0
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] || continue
  case "$rel" in tests/scripts/test-pipefail-grep-q-lint.sh) continue ;; esac
  checked=$((checked + 1))
  n=$(count "$ROOT/$rel")
  [ "$n" -eq 0 ] || bad "$rel: $n pipe(s) into grep -q; use grep -q PAT <<<\"\$x\" or <<<\"\$(cmd)\""
done < <(cd "$ROOT" && git ls-files '*.sh' 'git-hooks/*')

[ "$fail" -eq 0 ] && ok "no tracked shell file pipes into grep -q"
[ "$checked" -ge 100 ] && ok "lint saw $checked shell files (not vacuous)" \
  || bad "lint saw only $checked shell files; the file listing no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
