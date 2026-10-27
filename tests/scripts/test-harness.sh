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
# must delete nothing -- the actual incident this guards against is
# `trash ""` deleting the process's cwd. Run it from a fresh cwd and check
# that cwd is still there afterwards.
TD="$ROOT/tests/_lib/tmp_delete.py"
CWD3=$(mktemp -d)
ROOT_LOG3=$(mktemp)
(cd "$CWD3" && bash -c "
  . '$LIB'
  printf '%s' \"\$_HARNESS_ROOT\" > '$ROOT_LOG3'
  _HARNESS_ROOT=''
  FAKE_HOME=''
  EXTRA_TRASH=('' '')
  _cleanup_trash
")
LEAKED3=$(cat "$ROOT_LOG3" 2>/dev/null)
[ -n "$LEAKED3" ] && LEAKED_ROOTS+=("$LEAKED3")
if [ -d "$CWD3" ]; then
  ok "_cleanup_trash with only empty targets leaves the cwd alone"
else
  bad "_cleanup_trash with only empty targets deleted the cwd"
fi
python3 "$TD" "$CWD3" "$ROOT_LOG3"

# _cleanup_trash deletes every real non-empty target (FAKE_HOME, a mix of
# empty and real EXTRA_TRASH entries, and its own _HARNESS_ROOT), and a
# target the delete helper refuses (outside every temp root; it never
# exists, so a broken helper could not delete anything real) is reported
# without blocking the others.
FAKE_REAL_HOME=$(mktemp -d)
FAKE_REAL_EXTRA=$(mktemp -d)
ROOT_LOG4=$(mktemp)
ERR4=$(bash -c "
  . '$LIB'
  FAKE_HOME='$FAKE_REAL_HOME'
  EXTRA_TRASH=('' \"\$HOME/.mh-tmp-delete-refused-probe\" '$FAKE_REAL_EXTRA' '')
  printf '%s' \"\$_HARNESS_ROOT\" > '$ROOT_LOG4'
  _cleanup_trash
" 2>&1 >/dev/null)
LEAKED4=$(cat "$ROOT_LOG4" 2>/dev/null)
if [ -n "$LEAKED4" ] && [ ! -e "$LEAKED4" ] && [ ! -e "$FAKE_REAL_HOME" ] && [ ! -e "$FAKE_REAL_EXTRA" ]; then
  ok "_cleanup_trash deletes its root, FAKE_HOME and every real EXTRA_TRASH target"
else
  bad "_cleanup_trash left a target behind (root, FAKE_HOME or EXTRA_TRASH)"
  [ -n "$LEAKED4" ] && LEAKED_ROOTS+=("$LEAKED4")
fi
if /usr/bin/grep -q 'refused' <<<"$ERR4"; then
  ok "_cleanup_trash reports a refused target on stderr"
else
  bad "_cleanup_trash said nothing about a target outside every temp root"
fi
python3 "$TD" "$ROOT_LOG4" "$FAKE_REAL_HOME" "$FAKE_REAL_EXTRA"

# Every _HARNESS_ROOT the sub-invocations above created (as a side effect of
# sourcing harness.sh) and never deleted themselves.
[ "${#LEAKED_ROOTS[@]}" -gt 0 ] && python3 "$TD" "${LEAKED_ROOTS[@]}"

echo "tests/_lib/harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
