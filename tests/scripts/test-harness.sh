#!/usr/bin/env bash
# test-harness.sh — unit tests for tests/_lib/harness.sh, the shared
# fresh_tmpdir/fresh_repo/track_trash/_cleanup_trash trio 5 test files
# migrated to in v1.1.68. Direct, isolated coverage of the empty-string
# filter specifically: this is the exact bug class that moved this repo's
# working tree to Trash mid-session (`trash ""` deletes the cwd) --
# test-gap-analyzer finding, confirmed real: every existing call site
# passes a real path, so nothing exercises the filter itself in isolation.
# Run standalone: bash tests/scripts/test-harness.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
LIB="$ROOT/tests/_lib/harness.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== tests/_lib/harness.sh ==="

[ -f "$LIB" ] && ok "tests/_lib/harness.sh exists" || bad "tests/_lib/harness.sh missing"

# LEAKED_ROOTS: every `bash -c ". '$LIB'; ..."` below sources harness.sh,
# which creates its own real _HARNESS_ROOT tmpdir as a side effect of
# sourcing (fresh-context validator round finding: these isolated
# sub-invocations exist to test track_trash/_cleanup_trash directly, not
# to use fresh_tmpdir, but each still pays for -- and previously leaked --
# a real root dir). Each block below prints its own $_HARNESS_ROOT as its
# LAST line so this outer script can reclaim it in the final cleanup pass.
LEAKED_ROOTS=()

# track_trash "" must never append to EXTRA_TRASH.
OUT1=$(bash -c ". '$LIB'; track_trash \"\"; echo \"\${#EXTRA_TRASH[@]}\"; echo \"\$_HARNESS_ROOT\"")
COUNT=$(printf '%s\n' "$OUT1" | sed -n '1p')
[ -n "$(printf '%s\n' "$OUT1" | sed -n '2p')" ] && LEAKED_ROOTS+=("$(printf '%s\n' "$OUT1" | sed -n '2p')")
if [ "$COUNT" = "0" ]; then
  ok "track_trash '' does not add an empty string to EXTRA_TRASH"
else
  bad "track_trash '' should leave EXTRA_TRASH empty, got count=$COUNT"
fi

# track_trash with a real path DOES append it (the trio isn't just silent).
OUT2=$(bash -c ". '$LIB'; track_trash \"/tmp/some-real-path\"; echo \"\${#EXTRA_TRASH[@]}\"; echo \"\$_HARNESS_ROOT\"")
COUNT2=$(printf '%s\n' "$OUT2" | sed -n '1p')
[ -n "$(printf '%s\n' "$OUT2" | sed -n '2p')" ] && LEAKED_ROOTS+=("$(printf '%s\n' "$OUT2" | sed -n '2p')")
if [ "$COUNT2" = "1" ]; then
  ok "track_trash <real-path> adds exactly one entry to EXTRA_TRASH"
else
  bad "track_trash <real-path> expected count=1, got $COUNT2"
fi

# _cleanup_trash with EXTRA_TRASH full of empties and an empty FAKE_HOME
# must never invoke the real `trash` at all -- the actual incident this
# guards against is `trash ""` deleting the process's cwd. Shim `trash` to
# log its argv so we can assert it was never called with anything, not
# just that the process didn't crash.
TRASHSHIM=$(mktemp -d)
cat > "$TRASHSHIM/trash" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TRASH_LOG"
EOF
chmod +x "$TRASHSHIM/trash"
TRASH_LOG=$(mktemp)
ROOT_LOG3=$(mktemp)
export TRASH_LOG
PATH="$TRASHSHIM:$PATH" bash -c "
  . '$LIB'
  printf '%s' \"\$_HARNESS_ROOT\" > '$ROOT_LOG3'
  _HARNESS_ROOT=''
  FAKE_HOME=''
  EXTRA_TRASH=('' '')
  _cleanup_trash
"
LEAKED3=$(cat "$ROOT_LOG3" 2>/dev/null)
[ -n "$LEAKED3" ] && LEAKED_ROOTS+=("$LEAKED3")
if [ ! -s "$TRASH_LOG" ]; then
  ok "_cleanup_trash with only empty targets never invokes trash at all"
else
  bad "_cleanup_trash invoked trash with: $(cat "$TRASH_LOG")"
fi
CLEANUP1=()
[ -n "$TRASHSHIM" ] && CLEANUP1+=("$TRASHSHIM")
[ -n "$TRASH_LOG" ] && CLEANUP1+=("$TRASH_LOG")
[ -n "$ROOT_LOG3" ] && CLEANUP1+=("$ROOT_LOG3")
[ "${#CLEANUP1[@]}" -gt 0 ] && trash "${CLEANUP1[@]}" 2>/dev/null

# _cleanup_trash DOES invoke trash, once, with every real non-empty target
# (FAKE_HOME plus a mix of empty and real EXTRA_TRASH entries) -- proves the
# filter drops empties without also dropping real targets.
TRASHSHIM2=$(mktemp -d)
cat > "$TRASHSHIM2/trash" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TRASH_LOG2"
EOF
chmod +x "$TRASHSHIM2/trash"
TRASH_LOG2=$(mktemp)
ROOT_LOG4=$(mktemp)
export TRASH_LOG2
FAKE_REAL_HOME=$(mktemp -d)
FAKE_REAL_EXTRA=$(mktemp -d)
PATH="$TRASHSHIM2:$PATH" bash -c "
  . '$LIB'
  FAKE_HOME='$FAKE_REAL_HOME'
  EXTRA_TRASH=('' '$FAKE_REAL_EXTRA' '')
  printf '%s' \"\$_HARNESS_ROOT\" > '$ROOT_LOG4'
  _cleanup_trash
"
LEAKED4=$(cat "$ROOT_LOG4" 2>/dev/null)
[ -n "$LEAKED4" ] && LEAKED_ROOTS+=("$LEAKED4")
LOGGED=$(cat "$TRASH_LOG2" 2>/dev/null)
if /usr/bin/grep -qF "$FAKE_REAL_HOME" <<<"$LOGGED" && /usr/bin/grep -qF "$FAKE_REAL_EXTRA" <<<"$LOGGED" && ! /usr/bin/grep -qx '' <<<"$LOGGED"; then
  ok "_cleanup_trash trashes every real target, mixed with empties, without an empty argv element"
else
  bad "_cleanup_trash real-target pass failed: logged='$LOGGED'"
fi
CLEANUP2=()
for c in "$TRASHSHIM2" "$TRASH_LOG2" "$ROOT_LOG4" "$FAKE_REAL_HOME" "$FAKE_REAL_EXTRA"; do
  [ -n "$c" ] && CLEANUP2+=("$c")
done
[ "${#CLEANUP2[@]}" -gt 0 ] && trash "${CLEANUP2[@]}" 2>/dev/null

# Every _HARNESS_ROOT any of the 4 sub-invocations above created (as a side
# effect of sourcing harness.sh) and never itself trashed for real.
[ "${#LEAKED_ROOTS[@]}" -gt 0 ] && trash "${LEAKED_ROOTS[@]}" 2>/dev/null

echo "tests/_lib/harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
