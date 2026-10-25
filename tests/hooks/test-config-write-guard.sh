#!/usr/bin/env bash
# Behavioral tests for config-write-guard.sh (#98, deferred backlog from spec #75).
# Run standalone: bash tests/hooks/test-config-write-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/hooks/gates/config-write-guard.sh"

pass=0
fail=0

payload_write() { # payload_write <file_path>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":""}}))' "$1"
}

payload_write_content() { # payload_write_content <file_path> <content>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}

payload_edit() { # payload_edit <file_path> <old_string> <new_string> [replace_all:true|false]
  python3 -c '
import json, sys
replace_all = len(sys.argv) > 4 and sys.argv[4] == "true"
print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3],"replace_all":replace_all}}))
' "$1" "$2" "$3" "${4:-false}"
}

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

echo "=== config-write-guard gate ==="

FIXTURE=$(mktemp -d)
trap 'trash "$FIXTURE" 2>/dev/null || true' EXIT
# Isolate the gate-verdict journal (hooks/gates/_journal.py) from this file's
# ask-case assertions -- run standalone (this file's own header invites it),
# it would otherwise silently append rows to the operator's real
# ~/.local/share/kbg/metrics/gate-decisions.jsonl.
export MH_GATE_JOURNAL_PATH="$FIXTURE/gate-decisions.jsonl"
mkdir -p "$FIXTURE/.claude"

out=$(payload_write "$FIXTURE/.claude/settings.local.json" | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "CREATE .claude/settings.local.json (doesn't exist yet) -> ask" "$ok"

out=$(payload_write "$FIXTURE/.claude/settings.json" | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "CREATE .claude/settings.json (doesn't exist yet) -> ask" "$ok"

# Ordinary edit that never touches hooks/enabledPlugins stays frictionless.
# Both sides must be JSON objects (not "" -> {}), otherwise the unparseable
# original would hit the ask branch for the wrong reason and this assertion
# would pass without ever exercising the new comparison logic.
echo '{"foo":"bar"}' > "$FIXTURE/.claude/settings.local.json"
out=$(payload_write_content "$FIXTURE/.claude/settings.local.json" '{"foo":"bar","baz":true}' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "MODIFY existing .claude/settings.local.json, no hooks/enabledPlugins touched -> exit 0, no output" "$ok"

# Deliberate behavior change from the create-only version of this gate: a
# dangling symlink has no real content behind it, so the old "already
# occupied path = already reviewed" rationale never actually applied here --
# hooks/enabledPlugins genuinely can't be verified unchanged, so this now
# asks instead of waving through.
ln -s "$FIXTURE/.claude/does-not-exist-target" "$FIXTURE/.claude/settings.json"
out=$(payload_write "$FIXTURE/.claude/settings.json" | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "dangling symlink already at settings.json path -> unreadable, cannot verify -> ask" "$ok"
rm -f "$FIXTURE/.claude/settings.json"

# Regression: a stray non-UTF-8 byte anywhere in the on-disk file used to
# raise UnicodeDecodeError, which is NOT an OSError subclass -- it fell
# through the local except into the outer bare except and silently allowed,
# even when the edit unambiguously rewrites hooks. Found by compliance-audit
# adversarial verification 2026-08-30.
printf '{"hooks":{"PreToolUse":[]},\xff\xfe"other":1}' > "$FIXTURE/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/.claude/settings.json" '{"hooks":{"PreToolUse":[{"id":"evil"}]}}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "on-disk file has invalid UTF-8 byte, edit changes hooks -> unreadable, cannot verify -> ask" "$ok"
rm -f "$FIXTURE/.claude/settings.json"

out=$(payload_write "$FIXTURE/.claude/config.json" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "unrelated .claude/config.json (wrong basename) -> exit 0, no output" "$ok"

out=$(payload_write "$FIXTURE/settings.json" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "settings.json NOT under a .claude dir -> exit 0, no output" "$ok"

# Regression: a dotfiles setup symlinks ~/.claude/settings.json to a file in a repo dir
# that is not named .claude (dotfiles/claude/settings.json). Writing that real path
# skipped the gate, since only the parent dir name was checked. The real path of each
# known settings location (config dir, project dir, cwd) now counts as a settings file.
mkdir -p "$FIXTURE/home/.claude" "$FIXTURE/dot/claude" "$FIXTURE/proj/.claude" "$FIXTURE/projdot"
echo '{"hooks":{"PreToolUse":[]},"theme":"dark"}' > "$FIXTURE/dot/claude/settings.json"
ln -s "$FIXTURE/dot/claude/settings.json" "$FIXTURE/home/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/dot/claude/settings.json" '{"hooks":{"PreToolUse":[{"id":"evil"}]},"theme":"dark"}' | HOME="$FIXTURE/home" bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "real target of a symlinked ~/.claude/settings.json, edit changes hooks -> ask" "$ok"

out=$(payload_edit "$FIXTURE/dot/claude/settings.json" '"theme":"dark"' '"theme":"light"' | HOME="$FIXTURE/home" bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "real target of a symlinked ~/.claude/settings.json, unrelated key -> no friction" "$ok"

out=$(payload_write_content "$FIXTURE/dot/claude/settings.json" '{"hooks":{"PreToolUse":[{"id":"evil"}]}}' | HOME="$FIXTURE/home" CLAUDE_CONFIG_DIR="$FIXTURE/home/.claude" bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "CLAUDE_CONFIG_DIR points at the symlinked dir, edit changes hooks -> ask" "$ok"

ln -s "$FIXTURE/dot/claude/settings.local.json" "$FIXTURE/home/.claude/settings.local.json"
out=$(payload_write "$FIXTURE/dot/claude/settings.local.json" | HOME="$FIXTURE/home" bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "dangling ~/.claude/settings.local.json symlink, Write creates its target -> ask" "$ok"

echo '{"env":{}}' > "$FIXTURE/projdot/settings.json"
ln -s "$FIXTURE/projdot/settings.json" "$FIXTURE/proj/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/projdot/settings.json" '{"env":{"MH_ALLOW_MAIN_EDIT":"1"}}' | HOME="$FIXTURE/home" CLAUDE_PROJECT_DIR="$FIXTURE/proj" bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "real target of a symlinked project .claude/settings.json, edit changes env -> ask" "$ok"

out=$(payload_write_content "$FIXTURE/projdot/settings.json" '{"env":{"MH_ALLOW_MAIN_EDIT":"1"}}' | HOME="$FIXTURE/home" bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "settings.json that no known settings location resolves to -> exit 0, no output" "$ok"

# --- content-aware edit checks: hooks/enabledPlugins vs everything else ---

echo '{"hooks":{"PreToolUse":[]}}' > "$FIXTURE/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/.claude/settings.json" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"evil"}]}]}}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Write edit changes hooks key -> ask" "$ok"

echo '{"enabledPlugins":{"mh@wasikarn":true}}' > "$FIXTURE/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/.claude/settings.json" '{"enabledPlugins":{"mh@wasikarn":false}}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Write edit changes enabledPlugins key -> ask" "$ok"

# The matt-skill attack shape: inserting a new array entry next to an
# existing one. old_string/new_string deliberately never contain the literal
# substring "hooks" -- proving the check reconstructs and parses the full
# file rather than substring-matching the edited fragment for that word.
echo '{"hooks":{"PreToolUse":[{"id":"a","matcher":"Bash"}]},"other":1}' > "$FIXTURE/.claude/settings.json"
out=$(payload_edit "$FIXTURE/.claude/settings.json" '{"id":"a","matcher":"Bash"}]}' '{"id":"a","matcher":"Bash"},{"id":"evil","matcher":"Write"}]}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Edit inserts a new hooks.PreToolUse array entry (fragment has no literal 'hooks') -> ask" "$ok"

echo '{"hooks":{"PreToolUse":[]},"theme":"dark"}' > "$FIXTURE/.claude/settings.json"
out=$(payload_edit "$FIXTURE/.claude/settings.json" '"theme":"dark"' '"theme":"light"' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "Edit touches an unrelated key, hooks present elsewhere unchanged -> no friction" "$ok"

# replace_all correctness: the first occurrence of "tag" sits outside hooks
# (in "note"); the second sits inside hooks.PreToolUse. With replace_all
# true, both change, so hooks changes -> must ask. A hardcoded count=1 would
# only touch the first (outside hooks) occurrence and wrongly allow -- this
# is the one case that fails if the replace_all branch is dropped.
echo '{"note":"tag","hooks":{"PreToolUse":[{"id":"tag"}]}}' > "$FIXTURE/.claude/settings.json"
out=$(payload_edit "$FIXTURE/.claude/settings.json" 'tag' 'evil' 'true' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Edit with replace_all=true changes hooks via the 2nd occurrence -> ask" "$ok"

# Regression: macOS/APFS is case-insensitive but case-preserving, so
# .claude/SETTINGS.JSON resolves to the same on-disk file as
# .claude/settings.json -- a case-sensitive basename/parent compare let a
# one-character-case edit skip this gate entirely. Found by deep-audit
# adversarial verification 2026-08-30.
echo '{"hooks":{"PreToolUse":[]}}' > "$FIXTURE/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/.claude/SETTINGS.JSON" '{"hooks":{"PreToolUse":[{"id":"evil"}]}}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "uppercase .claude/SETTINGS.JSON resolves to the real file on a case-insensitive FS -> ask" "$ok"
rm -f "$FIXTURE/.claude/settings.json"

# Regression: SECURITY_KEYS originally covered only hooks/enabledPlugins.
# Claude Code's settings `env` block is injected into hook subprocess
# environments too (docs/reference/env-vars.md), and this repo's own gates
# already honor escape-hatch env vars (MH_ALLOW_MAIN_EDIT,
# MH_ALLOW_DIRECT_ATLASSIAN_MCP) -- a frictionless env-key edit could flip
# one of those without ever touching hooks/enabledPlugins. Found by
# deep-audit adversarial verification 2026-08-30.
echo '{"env":{"FOO":"bar"}}' > "$FIXTURE/.claude/settings.json"
out=$(payload_write_content "$FIXTURE/.claude/settings.json" '{"env":{"FOO":"bar","MH_ALLOW_MAIN_EDIT":"1"}}' | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Write edit changes env key -> ask" "$ok"
rm -f "$FIXTURE/.claude/settings.json"

# --- the bash fast path (_silent_fastpath.sh) must defer every payload python could ask on ---
# "~" expands to $HOME, which can supply the basename the raw payload never spells out.
out=$(payload_write "~" | HOME="$FIXTURE/home/.claude/settings.json" bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "file_path \"~\" with HOME ending in .claude/settings.json -> ask (fast path defers on ~)" "$ok"

# A \u escape can spell settings.json without the raw text containing it.
out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/se\\u0074tings.json","content":""}}' "$FIXTURE" | bash "$GUARD" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "\\u-escaped settings.json basename -> ask (fast path defers on \\u)" "$ok"

out=$(payload_edit "$FIXTURE/src/app.py" 'x = 1' 'x = 2' | bash "$GUARD" 2>&1); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "ordinary Edit elsewhere -> exit 0, no output, no stderr" "$ok"

# --- JSON depth: an extra key nested past the decoder's limit raises RecursionError ---
# A non-settings path is never asked on, so only the depth branch can ask here.
# depth 500, not 1000: Python <=3.11 overflows near 986.
deepen() { python3 -c 'import sys; s = sys.stdin.read().rstrip(); n = int(sys.argv[1]); print(s[:-1] + ", \"x\": " + "[" * n + "]" * n + "}")' "$1"; }
out=$(payload_write "$FIXTURE/src/app.py" | deepen 1000000 | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "JSON depth 1e6, Write to a non-settings path -> ask (payload not checked)" "$ok"
out=$(payload_write "$FIXTURE/src/app.py" | deepen 500 | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "JSON depth 500, Write to a non-settings path -> still parses, exit 0, no output" "$ok"
. "$ROOT/tests/_lib/memerr.sh"
out=$(payload_write "$FIXTURE/src/app.py" | memerr "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "json.load MemoryError, Write to a non-settings path -> ask (payload not checked)" "$ok"
err=$(printf '{"tool_name":"Write","tool_input":{' | bash "$GUARD" 2>&1 >/dev/null); rc=$?
out=$(printf '{"tool_name":"Write","tool_input":{' | bash "$GUARD" 2>/dev/null)
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && /usr/bin/grep -q "internal error, allowing" <<<"$err" && ok=0
check "truncated JSON -> still allows with the internal-error note (only depth asks)" "$ok"


echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
