#!/usr/bin/env bash
# Unit tests for skills/meta/learn/scripts/find-transcript.sh — the transcript
# locator whose old (pre-rebuild) design picked "latest .jsonl by mtime" and
# would silently mine the wrong session's transcript whenever this repo's own
# concurrent-session pattern put more than one transcript in a project dir.
# The fix reads CLAUDE_CODE_SESSION_ID and constructs the path deterministically.
# Run standalone: bash tests/skills/learn/test-find-transcript.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/skills/meta/learn/scripts/find-transcript.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

FAKE_HOME=$(mktemp -d)
trap 'python3 "$ROOT/tests/_lib/tmp_delete.py" "$FAKE_HOME" || true' EXIT
CWD="/fake/project"
SLUG="${CWD//\//-}"
DIR="$FAKE_HOME/.claude/projects/$SLUG"
mkdir -p "$DIR"

# --- fixture: two concurrent sessions, current one is NOT the latest by mtime ---
CURRENT_ID="11111111-1111-1111-1111-111111111111"
OTHER_ID="22222222-2222-2222-2222-222222222222"
printf 'current session content\n' > "$DIR/$CURRENT_ID.jsonl"
printf 'other, newer session content\n' > "$DIR/$OTHER_ID.jsonl"
# Explicit mtimes instead of a 1.1 s sleep: other is a minute newer than current.
touch -t 202601010000 "$DIR/$CURRENT_ID.jsonl"
touch -t 202601010001 "$DIR/$OTHER_ID.jsonl"

out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$CURRENT_ID" bash "$SCRIPT" "$CWD" 2>/dev/null)
rc=$?
picked_path=$(echo "$out" | awk '{print $1}')
if [ "$rc" -eq 0 ] && [ "$picked_path" = "$DIR/$CURRENT_ID.jsonl" ]; then
  ok "picks the current session's transcript, not the newer-mtime other session"
else
  bad "expected $DIR/$CURRENT_ID.jsonl, got '$picked_path' (rc=$rc) — old mtime-latest bug would pick $OTHER_ID.jsonl here"
fi

# --- fixture: session id set, but no matching transcript file exists ---
MISSING_ID="33333333-3333-3333-3333-333333333333"
STDOUT_LOG="$FAKE_HOME/missing-id.stdout"
STDERR_LOG="$FAKE_HOME/missing-id.stderr"
HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$MISSING_ID" bash "$SCRIPT" "$CWD" >"$STDOUT_LOG" 2>"$STDERR_LOG"
rc=$?
if [ "$rc" -ne 0 ] && [ -s "$STDERR_LOG" ]; then
  ok "fails loud (non-zero exit + stderr reason) when no transcript matches the session id"
else
  bad "expected non-zero exit + stderr on not-found, got rc=$rc stderr=$(cat "$STDERR_LOG")"
fi

# --- fixture: CLAUDE_CODE_SESSION_ID unset entirely ---
UNSET_STDERR_LOG="$FAKE_HOME/unset-id.stderr"
out=$(HOME="$FAKE_HOME" env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" "$CWD" 2>"$UNSET_STDERR_LOG")
rc=$?
if [ "$rc" -ne 0 ] && /usr/bin/grep -qi 'CLAUDE_CODE_SESSION_ID' "$UNSET_STDERR_LOG"; then
  ok "fails loud and names the missing env var when CLAUDE_CODE_SESSION_ID is unset"
else
  bad "expected non-zero exit naming CLAUDE_CODE_SESSION_ID, got rc=$rc stderr=$(cat "$UNSET_STDERR_LOG")"
fi

# --- byte size reported matches the actual file ---
out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$CURRENT_ID" bash "$SCRIPT" "$CWD" 2>/dev/null)
reported_size=$(echo "$out" | awk '{print $2}')
actual_size=$(wc -c < "$DIR/$CURRENT_ID.jsonl" | tr -d ' ')
if [ "$reported_size" = "$actual_size" ]; then
  ok "reported byte size matches the actual transcript file"
else
  bad "expected size $actual_size, got $reported_size"
fi

# --- slug rule must match the real CC runtime, not just "/" -> "-" ---
# Deep-audit 2026-09-07: the real runtime's own project-path slug function
# (confirmed in the installed CC binary's own source: `e.replace(/[^a-zA-Z0-9]/g,"-")`)
# replaces EVERY non-alphanumeric character, not just "/". This repo's own
# checkout path (letters and hyphens only) happens to produce an identical
# result either way, which is exactly why this went uncaught. A path
# containing an underscore is the smallest fixture that tells the two rules
# apart.
UNDERSCORE_CWD="/fake/my_project"
UNDERSCORE_SLUG="-fake-my-project"   # runtime rule: "_" -> "-" too
WRONG_SLUG="-fake-my_project"        # old script rule: only "/" -> "-"
UNDERSCORE_DIR="$FAKE_HOME/.claude/projects/$UNDERSCORE_SLUG"
mkdir -p "$UNDERSCORE_DIR"
UNDERSCORE_ID="44444444-4444-4444-4444-444444444444"
printf 'underscore project session content\n' > "$UNDERSCORE_DIR/$UNDERSCORE_ID.jsonl"
out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$UNDERSCORE_ID" bash "$SCRIPT" "$UNDERSCORE_CWD" 2>/dev/null)
rc=$?
picked_path=$(echo "$out" | awk '{print $1}')
if [ "$rc" -eq 0 ] && [ "$picked_path" = "$UNDERSCORE_DIR/$UNDERSCORE_ID.jsonl" ]; then
  ok "slug rule matches the real runtime for a path containing an underscore"
else
  bad "expected $UNDERSCORE_DIR/$UNDERSCORE_ID.jsonl, got '$picked_path' (rc=$rc) -- the old /-only rule would look in $FAKE_HOME/.claude/projects/$WRONG_SLUG instead"
fi

# --- a project path over 200 chars fails loud rather than guessing wrong
# (the real runtime hashes long paths with an internal function this script
# cannot replicate) ---
LONG_CWD="/fake/$(python3 -c 'print("x" * 250)')"
LONG_STDERR="$FAKE_HOME/long-path.stderr"
HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$CURRENT_ID" bash "$SCRIPT" "$LONG_CWD" >/dev/null 2>"$LONG_STDERR"
rc=$?
if [ "$rc" -ne 0 ] && /usr/bin/grep -qi 'over 200 chars' "$LONG_STDERR"; then
  ok "a >200-char project path fails loud instead of guessing at the real runtime's hash suffix"
else
  bad "expected non-zero exit naming the 200-char limit, got rc=$rc stderr=$(cat "$LONG_STDERR")"
fi

# --- GH #478: a session that started in another cwd keeps its transcript under that
# cwd's project folder; the session id is unique, so look for it in every project folder ---
MOVED_ID="55555555-5555-5555-5555-555555555555"
MOVED_DIR="$FAKE_HOME/.claude/projects/-fake-started-elsewhere"
mkdir -p "$MOVED_DIR"
printf 'moved session content\n' > "$MOVED_DIR/$MOVED_ID.jsonl"
out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$MOVED_ID" bash "$SCRIPT" "$CWD" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$(echo "$out" | awk '{print $1}')" = "$MOVED_DIR/$MOVED_ID.jsonl" ]; then
  ok "finds a transcript under another project folder when the cwd folder has none"
else
  bad "expected $MOVED_DIR/$MOVED_ID.jsonl, got '$out' (rc=$rc)"
fi

# the cwd folder still wins when it holds the id too
printf 'cwd copy\n' > "$DIR/$MOVED_ID.jsonl"
out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$MOVED_ID" bash "$SCRIPT" "$CWD" 2>/dev/null)
if [ "$(echo "$out" | awk '{print $1}')" = "$DIR/$MOVED_ID.jsonl" ]; then
  ok "the current project's folder wins over a search of the others"
else
  bad "expected the cwd folder copy, got '$out'"
fi
python3 "$ROOT/tests/_lib/tmp_delete.py" "$DIR/$MOVED_ID.jsonl"

# the same id in two other folders is ambiguous: fail loud and list both
TWIN_ID="66666666-6666-6666-6666-666666666666"
mkdir -p "$FAKE_HOME/.claude/projects/-fake-twin-a" "$FAKE_HOME/.claude/projects/-fake-twin-b"
printf 'a\n' > "$FAKE_HOME/.claude/projects/-fake-twin-a/$TWIN_ID.jsonl"
printf 'b\n' > "$FAKE_HOME/.claude/projects/-fake-twin-b/$TWIN_ID.jsonl"
TWIN_ERR="$FAKE_HOME/twin.stderr"
out=$(HOME="$FAKE_HOME" CLAUDE_CODE_SESSION_ID="$TWIN_ID" bash "$SCRIPT" "$CWD" 2>"$TWIN_ERR")
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && /usr/bin/grep -q 'twin-a' "$TWIN_ERR" && /usr/bin/grep -q 'twin-b' "$TWIN_ERR"; then
  ok "the same session id in two project folders fails loud and names both"
else
  bad "expected non-zero exit naming both folders, got rc=$rc out='$out' stderr=$(cat "$TWIN_ERR")"
fi

echo "learn/find-transcript: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
