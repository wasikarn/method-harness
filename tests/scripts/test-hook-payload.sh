#!/usr/bin/env bash
# test-hook-payload.sh — unit tests for scripts/_lib/hook_payload.py, the
# shared session_id validator that replaced 3 near-identical embedded
# python3 -c copies (the former hooks/session/handoff-nudge.sh, removed v1.1.94,
# hooks/sensors/fragments-arm.sh, hooks/sensors/fragments-capture.sh).
# Test list matches the exact cases the former handoff-nudge.sh's own comment named.
#
# Every assertion is against a HARDCODED expected value.
#
# Run standalone: bash tests/scripts/test-hook-payload.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
LIB_DIR="$ROOT/scripts/_lib"
MODULE="$LIB_DIR/hook_payload.py"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== hook_payload.py ==="

[ -f "$MODULE" ] && ok "scripts/_lib/hook_payload.py exists" || bad "scripts/_lib/hook_payload.py missing"

# --- validate_session_id() as an imported predicate ---
PRED_OUT=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from hook_payload import validate_session_id

cases = [
    ("s1", "s1"),
    ("abc-123_XY.z", "abc-123_XY.z"),
    (".", ""),
    ("..", ""),
    (None, ""),
    (123, ""),
    (True, ""),
    (3.14, ""),
    (["a"], ""),
    ({"a": 1}, ""),
    ("foo\n", ""),
    ("foo\x00bar", ""),
    ("foo bar", ""),
    ("", ""),
]
fails = 0
for val, want in cases:
    got = validate_session_id(val)
    if got != want:
        fails += 1
        print("MISMATCH %r -> %r (want %r)" % (val, got, want))
print("RESULT %d/%d" % (len(cases) - fails, len(cases)))
' "$LIB_DIR")
echo "$PRED_OUT" | /usr/bin/grep -v '^RESULT' | while read -r line; do [ -n "$line" ] && echo "    $line"; done
RESULT_LINE=$(echo "$PRED_OUT" | /usr/bin/grep '^RESULT')
if [ "$RESULT_LINE" = "RESULT 14/14" ]; then
  ok "validate_session_id: all 14 hardcoded cases pass (valid, ./.., non-str types, embedded newline/NUL, whitespace, empty)"
else
  bad "validate_session_id: expected RESULT 14/14, got '$RESULT_LINE'"
fi

# --- module run as a script (the former handoff-nudge.sh's call shape) ---
run_script() {
  printf '%s' "$1" | PYTHONPATH="$LIB_DIR" python3 -B "$MODULE"
}

OUT=$(run_script '{"session_id":"abc-123"}')
[ "$OUT" = "abc-123" ] && ok "script mode: valid session_id printed" || bad "script mode valid: got '$OUT'"

OUT=$(run_script '{"session_id":".."}')
[ "$OUT" = "" ] && ok "script mode: '..' session_id prints empty line" || bad "script mode '..': got '$OUT'"

OUT=$(run_script '{"session_id":null}')
[ "$OUT" = "" ] && ok "script mode: null session_id prints empty line" || bad "script mode null: got '$OUT'"

OUT=$(run_script 'not json at all')
[ "$OUT" = "" ] && ok "script mode: malformed JSON prints empty line, does not crash" || bad "script mode malformed: got '$OUT'"

OUT=$(run_script '["not","a","dict"]')
[ "$OUT" = "" ] && ok "script mode: non-dict top-level JSON prints empty line" || bad "script mode non-dict: got '$OUT'"

OUT=$(run_script '{}')
[ "$OUT" = "" ] && ok "script mode: missing session_id field prints empty line" || bad "script mode missing field: got '$OUT'"

# -B must prevent a bytecode cache write when run as a script.
# Only hook_payload's own bytecode counts: sibling tests import other scripts/_lib modules
# (verdict_json) concurrently under the sharded gauntlet and legitimately create __pycache__/.
_hp_pyc() { find "$LIB_DIR" -path '*/__pycache__/hook_payload*' -name '*.pyc' 2>/dev/null; }
PYCACHE_BEFORE=$(_hp_pyc | wc -l | tr -d ' ')
[ "$PYCACHE_BEFORE" = "0" ] || _hp_pyc | while IFS= read -r _f; do trash "$_f"; done
run_script '{"session_id":"s1"}' >/dev/null
# Script mode never caches the script itself, so also import the module: this is the run that would
# write hook_payload's .pyc into scripts/_lib if -B were dropped.
PYTHONPATH="$LIB_DIR" python3 -B -c 'import hook_payload'
PYCACHE_AFTER=$(_hp_pyc | wc -l | tr -d ' ')
if [ "$PYCACHE_AFTER" = "0" ]; then
  ok "-B prevents a __pycache__/ write in scripts/_lib at hook runtime"
else
  bad "-B did not prevent a __pycache__/ write (found $PYCACHE_AFTER)"
  _hp_pyc | while IFS= read -r _f; do trash "$_f"; done
fi

# --- deep-audit finding, live-reproduced with a planted glob.py: every
# remaining inline `python3 -c` block across the fragments hooks/lib
# imports stdlib-only names (glob, hashlib, json, os, re, subprocess, sys)
# that are equally shadow-able by a same-named file in the hook's own cwd
# -- the first round only closed this for the two by-path parsers, which
# import the local hook_payload module and correctly do NOT use -I (they
# need scripts/_lib/ on sys.path). Every remaining site must use `python3
# -I -c`, which drops cwd from sys.path without needing a by-path rewrite. ---
BARE=$(/usr/bin/grep -rn "python3 -c '" \
  "$ROOT/hooks/sensors/fragments-arm.sh" \
  "$ROOT/hooks/sensors/fragments-capture.sh" \
  "$ROOT/hooks/session/fragments-surface.sh" \
  "$ROOT/scripts/_lib/fragments-state.sh" 2>/dev/null)
if [ -z "$BARE" ]; then
  ok "no bare 'python3 -c' (missing -I) remains in any fragments hook or lib"
else
  bad "found a stdlib-importing python3 -c without -I: $BARE"
fi

echo "hook_payload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
