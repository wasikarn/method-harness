#!/usr/bin/env bash
# test-trash-empty-guard-lint.sh — a test must never hand `trash` a variable it got from a
# template-form mktemp (`mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"`). With TMPDIR naming a missing
# directory that mktemp prints "mkdtemp failed" and returns "", `set -u` does not catch an empty
# variable, and `trash ""` moves the CURRENT DIRECTORY (the repo root under the gauntlet) to the
# Trash: the incident tests/_lib/harness.sh records. Plain `mktemp -d` falls back on macOS, so only
# the template form is linted. The fix: delete the temp dir with scripts/_lib/tmp_delete.py (it refuses
# an empty argument and anything outside a temp root itself, so it is never flagged), or source
# tests/_lib/harness.sh, `track_trash "$VAR"`, and `trap _cleanup_trash EXIT` (GH #724).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/_lib/tmp-delete.sh"
ROOT="$HERE/../.."
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

# Owned by other work in flight; each still holds the pattern and is tracked for a follow-up.
# The lint fails once a listed file is clean, so the entry gets dropped.
PENDING=" "

# Prints "line: var" for each trash call that names a template-mktemp variable as a whole argument.
# A trash call is `trash` in command position (line start, after ; & | ( { or a quote opening a trap
# string, or after then/do/else); `track_trash` and `grep 'no trash CLI'` are not.
hits() {
  awk '
    match($0, /[A-Za-z_][A-Za-z0-9_]*=\$\(mktemp [^)]*XXX/) {
      a = substr($0, RSTART, RLENGTH); sub(/=.*/, "", a); vars[a] = 1
    }
    /(^|[;&|({'"'"'"]|then|do|else)[ \t]*trash[ \t]/ {
      for (v in vars) {
        if ($0 ~ ("\\$(" v "|\\{" v "\\})(\"|[ \t;)]|$)")) print FNR ": " v
      }
    }
  ' "$1"
}

echo "=== template-form mktemp never reaches a bare trash ==="

# The lint sees the shape at all: a planted bad file must be caught, a guarded one must pass.
probe=$(mktemp -d)
cat > "$probe/bad.sh" <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
trap 'trash "$TMP" 2>/dev/null || true' EXIT
EOF
cat > "$probe/good.sh" <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
track_trash "$TMP"
trap _cleanup_trash EXIT
trash "$TMP/sub"
grep -q 'no trash CLI' "$TMP"
EOF
cat > "$probe/bad2.sh" <<'EOF'
FIX=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
cleanup() { trash "$FIX" 2>/dev/null || true; }
EOF
[ -n "$(hits "$probe/bad.sh")" ] && ok "probe: an unguarded trash in a trap string is caught" \
  || bad "probe: the lint missed an unguarded trash in a trap string"
[ -n "$(hits "$probe/bad2.sh")" ] && ok "probe: an unguarded trash in a cleanup function is caught" \
  || bad "probe: the lint missed an unguarded trash in a cleanup function"
[ -z "$(hits "$probe/good.sh")" ] && ok "probe: track_trash, a compound path and a quoted 'trash' word are not flagged" \
  || bad "probe: the lint flagged a guarded file"
[ -n "$probe" ] && tmp_delete "$probe"

checked=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  case "$rel" in tests/scripts/test-trash-empty-guard-lint.sh) continue ;; esac
  /usr/bin/grep -q 'mktemp [^)]*XXX' "$f" || continue
  checked=$((checked + 1))
  h=$(hits "$f")
  case "$PENDING" in
    *" $rel "*)
      [ -n "$h" ] && ok "$rel: still pending (follow-up), $(printf '%s' "$h" | tr '\n' ',')" \
        || bad "$rel is clean now: drop it from PENDING" ;;
    *)
      [ -z "$h" ] && ok "$rel: no template-mktemp var reaches a bare trash" \
        || bad "$rel hands trash a template-mktemp var (empty when mktemp fails): $(printf '%s' "$h" | tr '\n' ',') -- use tmp_delete (scripts/_lib/tmp-delete.sh), or track_trash + _cleanup_trash from tests/_lib/harness.sh" ;;
  esac
done < <(find "$ROOT/tests" -type f -name '*.sh' | sort)

[ "$checked" -ge 5 ] && ok "lint saw $checked files with a template mktemp (not vacuous)" \
  || bad "lint saw only $checked files with a template mktemp; the pattern no longer matches"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
