#!/usr/bin/env bash
# test-hook-common.sh — unit tests for scripts/_lib/hook-common.sh, the
# shared symlink/ownership, snapshot, age, title, and git-root helpers that
# replaced 3 copies of owner_ok(), the diverging stat-fallback direction
# between fragments-capture.sh and fragments-surface.sh, and the duplicated
# title-extraction / git-root-resolution blocks
# (docs/adr/0003-writing-fragments-pointer-capture.md).
#
# Every assertion below is against a HARDCODED expected value, never a
# value the lib computes for itself -- this repo's existing use of
# slug_hash() as a test oracle would let a deterministically-wrong
# implementation pass every test that only checks self-consistency.
#
# Run standalone: bash tests/scripts/test-hook-common.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$ROOT/scripts/_lib/tmp-delete.sh"
LIB="$ROOT/scripts/_lib/hook-common.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

T=$(mktemp -d)
EXTRA_TRASH=()
cleanup() {
  local targets=()
  local t
  [ -n "$T" ] && targets+=("$T")
  for t in "${EXTRA_TRASH[@]:-}"; do
    [ -n "$t" ] && targets+=("$t")
  done
  [ "${#targets[@]}" -gt 0 ] && tmp_delete "${targets[@]}"
  return 0
}
trap cleanup EXIT

echo "=== hook-common.sh ==="

# --- hook_owner_ok ---
if bash -c ". '$LIB'; hook_owner_ok '$T'"; then
  ok "hook_owner_ok true for a dir we own"
else
  bad "hook_owner_ok should be true for a dir we own"
fi

# --- hook_safe_dir ---
D="$T/safe/nested"
OUT=$(bash -c ". '$LIB'; hook_safe_dir '$D' && echo created")
if [ "$OUT" = "created" ] && [ -d "$D" ]; then
  MODE=$(stat -c '%a' "$D" 2>/dev/null || stat -f '%Lp' "$D" 2>/dev/null)
  if [ "$MODE" = "700" ]; then
    ok "hook_safe_dir creates a 700 dir"
  else
    bad "hook_safe_dir dir mode expected 700, got $MODE"
  fi
else
  bad "hook_safe_dir did not create $D (out=$OUT)"
fi

# hook_safe_dir must reject a symlinked path
LINK="$T/safe-link"
ln -s "$T" "$LINK"
if bash -c ". '$LIB'; hook_safe_dir '$LINK'" 2>/dev/null; then
  bad "hook_safe_dir accepted a symlink -- should reject"
else
  ok "hook_safe_dir rejects a symlinked path"
fi

# --- hook_snapshot ---
F="$T/f.txt"
printf 'hello' > "$F"
SNAP=$(bash -c ". '$LIB'; hook_snapshot '$F' at-read")
case "$SNAP" in
  '5 '*)
    ok "hook_snapshot reports the correct byte size (5)"
    ;;
  *)
    bad "hook_snapshot expected to start with '5 ', got '$SNAP'"
    ;;
esac

# hook_snapshot: two DISTINCT labels on a stat failure must never compare
# equal (handoff-surface.sh's own deep-audit finding: a shared "" fallback
# fails the guard open).
STATSHIM=$(mktemp -d)
EXTRA_TRASH+=("$STATSHIM")
cat > "$STATSHIM/stat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STATSHIM/stat"
SNAP_A=$(PATH="$STATSHIM:$PATH" bash -c ". '$LIB'; hook_snapshot '$F' at-read")
SNAP_B=$(PATH="$STATSHIM:$PATH" bash -c ". '$LIB'; hook_snapshot '$F' at-move")
if [ "$SNAP_A" = "stat-unavailable-at-read" ] && [ "$SNAP_B" = "stat-unavailable-at-move" ] && [ "$SNAP_A" != "$SNAP_B" ]; then
  ok "hook_snapshot: distinct labels never compare equal on stat failure"
else
  bad "hook_snapshot label distinctness broken: a='$SNAP_A' b='$SNAP_B'"
fi

# --- hook_snapshot vs fragments-surface.sh's own Python snapshot(): must
# produce byte-identical output on the same fixture. The Python one stays
# Python (it never shells into bash); this is the anti-drift mechanism.
# test-gap-analyzer finding: a pasted copy of the Python function here could
# silently drift from the real one in fragments-surface.sh with nobody
# noticing. Extract the real snapshot() function's source out of the hook
# file via ast (not a text/regex match, which would break on reformatting)
# and exec THAT, so this test fails the moment the two actually diverge. ---
PY_SNAP=$(python3 -c '
import ast, re, subprocess, sys
hook_path, target = sys.argv[1], sys.argv[2]
with open(hook_path) as fh:
    hook_src = fh.read()
# The Python block lives inside a bash single-quoted `python3 -c "..."`
# heredoc, not as standalone Python source -- pull just that embedded
# script out before handing it to ast.parse.
q = chr(39)
pat = "python3 [^\\n]*-c " + q + "\n(.*?)\n" + q
m = re.search(pat, hook_src, re.S)
if not m:
    sys.exit("no embedded python3 -c block found in " + hook_path)
py_src = m.group(1)
tree = ast.parse(py_src)
fn_src = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "snapshot":
        fn_src = ast.get_source_segment(py_src, node)
        break
if fn_src is None:
    sys.exit("snapshot() not found in " + hook_path)
ns = {"subprocess": subprocess}
exec(fn_src, ns)
result = ns["snapshot"](target)
if result is not None:
    print(result)
' "$ROOT/hooks/session/fragments-surface.sh" "$F")
BASH_SNAP=$(bash -c ". '$LIB'; hook_snapshot '$F' x")
if [ "$PY_SNAP" = "$BASH_SNAP" ]; then
  ok "hook_snapshot and fragments-surface.sh's Python snapshot() agree byte-for-byte"
else
  bad "snapshot format drift: bash='$BASH_SNAP' python='$PY_SNAP'"
fi

# --- hook_entry_age ---
NOW=$(date +%s)
AGE=$(bash -c ". '$LIB'; hook_entry_age '$F' '$NOW'")
if [ "$AGE" -ge 0 ] && [ "$AGE" -lt 5 ]; then
  ok "hook_entry_age reports ~0 for a just-created file"
else
  bad "hook_entry_age expected a small age, got '$AGE'"
fi

# hook_entry_age on stat failure: prints nothing, returns non-zero -- it
# must never guess an age (this is the direction fix: neither "treat as
# ancient" nor "treat as brand new").
RC=0
AGE_FAIL=$(PATH="$STATSHIM:$PATH" bash -c ". '$LIB'; hook_entry_age '$F' '$NOW'") || RC=$?
if [ "$RC" -ne 0 ] && [ -z "$AGE_FAIL" ]; then
  ok "hook_entry_age prints nothing and returns non-zero on stat failure"
else
  bad "hook_entry_age on stat failure: rc=$RC output='$AGE_FAIL' (expected non-zero rc, empty output)"
fi

# hook_entry_age on a missing path
RC=0
AGE_MISS=$(bash -c ". '$LIB'; hook_entry_age '$T/does-not-exist' '$NOW'") || RC=$?
if [ "$RC" -ne 0 ] && [ -z "$AGE_MISS" ]; then
  ok "hook_entry_age prints nothing and returns non-zero for a missing path"
else
  bad "hook_entry_age on missing path: rc=$RC output='$AGE_MISS'"
fi

# --- hook_md_title ---
cat > "$T/titled.md" <<'EOF'
# My Working Title
some body text
EOF
TITLE=$(bash -c ". '$LIB'; hook_md_title '$T/titled.md'")
if [ "$TITLE" = "My Working Title" ]; then
  ok "hook_md_title strips a leading '# '"
else
  bad "hook_md_title expected 'My Working Title', got '$TITLE'"
fi

cat > "$T/untitled.md" <<'EOF'
no heading on the first line
EOF
TITLE2=$(bash -c ". '$LIB'; hook_md_title '$T/untitled.md'")
if [ "$TITLE2" = "untitled" ]; then
  ok "hook_md_title falls back to the literal 'untitled'"
else
  bad "hook_md_title expected 'untitled', got '$TITLE2'"
fi

TITLE3=$(bash -c ". '$LIB'; hook_md_title '$T/does-not-exist.md'")
if [ "$TITLE3" = "untitled" ]; then
  ok "hook_md_title falls back to 'untitled' on a missing file, never fails"
else
  bad "hook_md_title on a missing file expected 'untitled', got '$TITLE3'"
fi

# --- hook_repo_root ---
REPO="$T/repo"
mkdir -p "$REPO/sub"
(cd "$REPO" && git init -q && git config user.email t@t.com && git config user.name t) >/dev/null 2>&1
REPO_REAL=$(cd -P "$REPO" && pwd)

ROOT_AMBIENT=$(cd "$REPO/sub" && bash -c ". '$LIB'; hook_repo_root")
if [ "$ROOT_AMBIENT" = "$REPO_REAL" ]; then
  ok "hook_repo_root (no arg) resolves from ambient cwd"
else
  bad "hook_repo_root ambient expected '$REPO_REAL', got '$ROOT_AMBIENT'"
fi

ROOT_ANCHORED=$(cd / && bash -c ". '$LIB'; hook_repo_root '$REPO/sub'")
if [ "$ROOT_ANCHORED" = "$REPO_REAL" ]; then
  ok "hook_repo_root <anchor> resolves anchored at a different cwd"
else
  bad "hook_repo_root anchored expected '$REPO_REAL', got '$ROOT_ANCHORED'"
fi

NONGIT="$T/plain-dir"
mkdir -p "$NONGIT"
NONGIT_REAL=$(cd -P "$NONGIT" && pwd)
ROOT_NONGIT=$(bash -c ". '$LIB'; hook_repo_root '$NONGIT'")
if [ "$ROOT_NONGIT" = "$NONGIT_REAL" ]; then
  ok "hook_repo_root falls back to the physical cwd outside a git repo"
else
  bad "hook_repo_root non-git expected '$NONGIT_REAL', got '$ROOT_NONGIT'"
fi

RC=0
ROOT_BAD=$(bash -c ". '$LIB'; hook_repo_root '$T/nonexistent-anchor'") || RC=$?
if [ "$RC" -ne 0 ] && [ -z "$ROOT_BAD" ]; then
  ok "hook_repo_root prints nothing and returns non-zero for a nonexistent anchor"
else
  bad "hook_repo_root bad anchor: rc=$RC output='$ROOT_BAD'"
fi

# hook_repo_root "" (an explicit empty-string anchor) must behave IDENTICALLY
# to omitting the argument -- ambient resolution -- documenting the exact
# distinction real callers (fragments-arm.sh, fragments-capture.sh) guard
# against by checking `[ -n "$CWD" ]` BEFORE ever calling this function with
# a payload-sourced value that could legitimately be empty.
ROOT_EMPTY=$(cd "$REPO/sub" && bash -c ". '$LIB'; hook_repo_root ''")
if [ "$ROOT_EMPTY" = "$ROOT_AMBIENT" ]; then
  ok "hook_repo_root '' (explicit empty string) matches no-arg ambient resolution exactly"
else
  bad "hook_repo_root '' expected to match ambient '$ROOT_AMBIENT', got '$ROOT_EMPTY'"
fi

# --- real GNU stat: never exercised by any other test in this repo, on any
# platform (CI runs `ubuntu-latest` but never runs the hook test suite
# there; every local/macOS test that reaches a real `stat` exercises the
# now-second-tried BSD `-f` branch, since hook-common.sh tries GNU's `-c`
# first). A shim that `exec gstat "$@"` -- a real GNU coreutils binary via
# homebrew, not a fake case-statement standing in for one -- proves the
# GNU-first branch, its format-string arguments, and the actual GNU
# multi-operand collision this ordering exists to avoid, all against real
# GNU stat behavior instead of a guess at what it does. ---
GNUSTAT=""
if command -v gstat >/dev/null 2>&1; then
  GNUSTAT=$(command -v gstat)
elif grep -q 'GNU coreutils' <<<"$(stat --version 2>/dev/null)"; then
  GNUSTAT=$(command -v stat)
fi
if [ -n "$GNUSTAT" ]; then
  GNUSHIM=$(mktemp -d)
  EXTRA_TRASH+=("$GNUSHIM")
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$GNUSTAT" > "$GNUSHIM/stat"
  chmod +x "$GNUSHIM/stat"

  if PATH="$GNUSHIM:$PATH" bash -c ". '$LIB'; hook_owner_ok '$T'"; then
    ok "hook_owner_ok resolves ownership correctly under a real GNU stat"
  else
    bad "hook_owner_ok failed under a real GNU stat (uid check)"
  fi

  SNAP_GNU=$(PATH="$GNUSHIM:$PATH" bash -c ". '$LIB'; hook_snapshot '$F' x")
  EXPECT_SNAP=$("$GNUSTAT" -c '%s %Y' "$F")
  if [ "$SNAP_GNU" = "$EXPECT_SNAP" ]; then
    ok "hook_snapshot produces the correct 'size mtime' format under a real GNU stat"
  else
    bad "hook_snapshot under real GNU stat: expected '$EXPECT_SNAP', got '$SNAP_GNU'"
  fi

  AGE_GNU=$(PATH="$GNUSHIM:$PATH" bash -c ". '$LIB'; hook_entry_age '$F' \$(( \$('$GNUSTAT' -c '%Y' '$F') + 3600 ))")
  if [ "$AGE_GNU" = "3600" ]; then
    ok "hook_entry_age computes the correct age under a real GNU stat"
  else
    bad "hook_entry_age under real GNU stat: expected 3600, got '$AGE_GNU'"
  fi
else
  echo "  (skipped: real-GNU-stat regression checks need gstat or native GNU stat -- brew install coreutils on macOS)"
fi

echo "hook-common: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
