#!/usr/bin/env bash
# Behavioral tests for codex-setup-guard.sh (H5, harness gap-audit 2026-09-20:
# this gate had zero test coverage). Same shape as
# tests/hooks/test-config-write-guard.sh: ask on the flagged case, allow
# everywhere else, allow on malformed stdin (fail-open is this gate's
# documented posture -- see codex-setup-guard.py's own header: the toggle it
# guards is trivially reversible and low-stakes, unlike irrecoverable.py's
# destructive-action gate, which fails CLOSED on malformed input instead;
# these two postures are each correct for their own gate, not an
# inconsistency to "normalize").
# Run standalone: bash tests/hooks/test-codex-setup-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/hooks/gates/codex-setup-guard.sh"

pass=0
fail=0

FIXTURE=$(mktemp -d)
trap 'python3 "$ROOT/tests/_lib/tmp_delete.py" "$FIXTURE" || true' EXIT
export MH_GATE_JOURNAL_PATH="$FIXTURE/gate-decisions.jsonl"

payload_skill() { # payload_skill <skill> <args>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Skill","tool_input":{"skill":sys.argv[1],"args":sys.argv[2]}}))' "$1" "$2"
}

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

echo "=== codex-setup-guard gate ==="

out=$(payload_skill "codex:setup" "--enable-review-gate" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "codex:setup --enable-review-gate -> ask" "$ok"

out=$(payload_skill "codex:setup" "--enable-review-gate --verbose" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "codex:setup --enable-review-gate mixed with other flags -> ask" "$ok"

out=$(payload_skill "codex:setup" "--disable-review-gate" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "codex:setup --disable-review-gate (no flag match) -> exit 0, no output" "$ok"

out=$(payload_skill "codex:setup" "" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "codex:setup with no args -> exit 0, no output" "$ok"

out=$(payload_skill "codex:rescue" "--enable-review-gate" | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "a different skill (codex:rescue) carrying the same flag -> exit 0, out of scope by design" "$ok"

out=$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"echo hi"}}))' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "non-Skill tool call -> exit 0, out of scope" "$ok"

out=$(python3 -c 'import json; print(json.dumps({"tool_name":"Skill","tool_input":"not-an-object"}))' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "tool_input not an object -> exit 0, allowed" "$ok"

out=$(python3 -c 'import json; print(json.dumps({"tool_name":"Skill","tool_input":{"skill":"codex:setup","args":42}}))' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "args wrong type (not a string) -> exit 0, allowed (fail-open on unexpected shape)" "$ok"

out=$(printf '%s' '{not valid json' | bash "$GUARD" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "malformed stdin (fail-open allow, this gate's documented posture) -> exit 0, no output" "$ok"

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
