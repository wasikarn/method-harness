#!/usr/bin/env bash
# test-gauntlet-trash-preflight.sh — regression for cloud audit 2026-10-23 F4: tests reset
# their state with `trash ... || true`, so a gauntlet run without trash let a row read the
# last row's leftovers (a stale marker read "python yes" in test-subagent-git-guard.sh).
# run-gauntlet.sh must stop before any test when trash is not on PATH. The same holds for shfmt,
# which tests/scripts/test-pipefail-grep-q-lint.sh needs to parse the shell files.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
BASH_BIN="$(command -v bash)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && trash "$1" 2>/dev/null; return 0; }

echo "=== gauntlet refuses to run without trash (cloud audit F4) or shfmt ==="

STUB="$(mktemp -d)"
[ -n "$STUB" ] && [ -d "$STUB" ] || { echo "mktemp -d failed" >&2; exit 1; }
# PATH holds only dirname (the script's first external) and, for the control, a trash
# stub and a failing mktemp: the control stops at the log dir, right after the preflight.
ln -s "$(command -v dirname)" "$STUB/dirname"

err=$(PATH="$STUB" "$BASH_BIN" "$GAUNTLET" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'trash not found' <<<"$err"; then
  ok "no trash on PATH: exit 2 naming trash, before any test"
else
  bad "no trash on PATH: expected exit 2 + 'trash not found', got rc=$rc: $err"
fi

printf '#!/bin/sh\nexit 0\n' > "$STUB/trash"
printf '#!/bin/sh\nexit 1\n' > "$STUB/mktemp"
chmod +x "$STUB/trash" "$STUB/mktemp"
err=$(PATH="$STUB" "$BASH_BIN" "$GAUNTLET" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'shfmt not found' <<<"$err" && ! /usr/bin/grep -q 'trash not found' <<<"$err"; then
  ok "trash but no shfmt on PATH: exit 2 naming shfmt, before any test"
else
  bad "trash but no shfmt on PATH: expected exit 2 + 'shfmt not found', got rc=$rc: $err"
fi

printf '#!/bin/sh\nexit 0\n' > "$STUB/shfmt"
chmod +x "$STUB/shfmt"
err=$(PATH="$STUB" "$BASH_BIN" "$GAUNTLET" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'mktemp -d failed' <<<"$err" && ! /usr/bin/grep -qE '(trash|shfmt) not found' <<<"$err"; then
  ok "trash and shfmt on PATH: preflight passes (control stops at the stubbed mktemp)"
else
  bad "trash and shfmt on PATH: expected the preflight to pass and mktemp to stop the run, got rc=$rc: $err"
fi

safe_trash "$STUB"
echo "trash preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
