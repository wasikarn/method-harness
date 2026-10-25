#!/usr/bin/env bash
# Regression test for the mh:gate-report skill's script,
# skills/meta/gate-report/scripts/gate-report.py. Points it at a synthetic
# MH_GATE_JOURNAL_PATH so it never touches the real
# ~/.local/share/kbg/metrics/gate-decisions.jsonl, and checks the ask-count math
# plus the missing-file and malformed-line paths.
# Run standalone: bash tests/skills/test-gate-report.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_PY="$ROOT/skills/meta/gate-report/scripts/gate-report.py"
SKILL_MD="$ROOT/skills/meta/gate-report/SKILL.md"

pass=0
fail=0

assert() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

[[ -f "$REPORT_PY" ]] || { echo "FATAL: $REPORT_PY not found — the gate-report skill's script moved without updating this test" >&2; exit 1; }
[[ -f "$SKILL_MD" ]] || { echo "FATAL: $SKILL_MD not found — the skill moved without updating this test" >&2; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'trash "$TMPDIR_TEST" 2>/dev/null || rm -rf "$TMPDIR_TEST"' EXIT

echo "=== gate-report ==="

# Wiring guard: the skill must invoke this exact script, not a copy.
assert "SKILL.md references scripts/gate-report.py" \
  "$(grep -q 'scripts/gate-report.py' "$SKILL_MD" && echo 1 || echo 0)"

JOURNAL="$TMPDIR_TEST/gate-decisions.jsonl"
cat > "$JOURNAL" <<'EOF'
{"ts": "2026-09-27T10:00:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "ask", "session_id": "s1"}
{"ts": "2026-09-27T10:05:00Z", "id": "gate:write:secret-scan", "tool_name": "Edit", "decision": "ask", "session_id": "s1"}
{"ts": "2026-09-28T09:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": "s2"}
{"ts": "2026-09-28T09:10:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "allow-suppressed", "session_id": "s2"}
not-json-garbage
EOF

out="$(MH_GATE_JOURNAL_PATH="$JOURNAL" python3 "$REPORT_PY")"
rc=$?
assert "exits 0 on a populated journal" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
assert "counts 4 events, skips the 1 garbage line" \
  "$(grep -q '^Gate journal: 4 ask/deny event(s), 1 unparsable or non-object line(s) skipped$' <<<"$out" && echo 1 || echo 0)"
assert "secret-scan ask count is 2, not double-counted across tools" \
  "$(grep -qE '^ *2  gate:write:secret-scan  ask$' <<<"$out" && echo 1 || echo 0)"
assert "irrecoverable deny counted separately from secret-scan" \
  "$(grep -qE '^ *1  gate:bash:irrecoverable  deny$' <<<"$out" && echo 1 || echo 0)"
assert "allow-suppressed kept as its own decision bucket, not folded into ask" \
  "$(grep -qE '^ *1  gate:write:secret-scan  allow-suppressed$' <<<"$out" && echo 1 || echo 0)"
assert "range line uses the earliest and latest ts" \
  "$(grep -q '^Range: 2026-09-27T10:00:00Z .. 2026-09-28T09:10:00Z$' <<<"$out" && echo 1 || echo 0)"

MISSING="$TMPDIR_TEST/does-not-exist.jsonl"
out_missing="$(MH_GATE_JOURNAL_PATH="$MISSING" python3 "$REPORT_PY")"
rc_missing=$?
assert "missing journal exits 0" "$([[ $rc_missing -eq 0 ]] && echo 1 || echo 0)"
assert "missing journal prints the documented line, not a traceback" \
  "$([[ "$out_missing" == "Gate journal not set up." ]] && echo 1 || echo 0)"

# GH #378: secret-scan journals its suppressed matches as one row with "count": N. The report counts
# matches, as it did when each match had its own row; a count that is not a positive int counts 1.
COUNTED="$TMPDIR_TEST/counted.jsonl"
cat > "$COUNTED" <<'EOF'
{"ts": "2026-10-03T10:00:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "allow-suppressed", "session_id": "s1"}
{"ts": "2026-10-03T10:01:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "allow-suppressed", "session_id": "s1", "count": 3}
{"ts": "2026-10-03T10:01:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "ask", "session_id": "s1"}
{"ts": "2026-10-03T10:02:00Z", "id": "gate:write:secret-scan", "tool_name": "Edit", "decision": "allow-suppressed", "session_id": "s1", "count": "x"}
{"ts": "2026-10-03T10:03:00Z", "id": "gate:write:secret-scan", "tool_name": "Edit", "decision": "allow-suppressed", "session_id": "s1", "count": true}
{"ts": "2026-10-03T10:04:00Z", "id": "gate:write:secret-scan", "tool_name": "Edit", "decision": "allow-suppressed", "session_id": "s1", "count": 0}
EOF
out_counted="$(MH_GATE_JOURNAL_PATH="$COUNTED" python3 "$REPORT_PY")"
assert "a count row adds its count: 1 + 3 + three malformed counts at 1 each = 7 allow-suppressed" \
  "$(grep -qE '^ *7  gate:write:secret-scan  allow-suppressed$' <<<"$out_counted" && echo 1 || echo 0)"
assert "the header total and the per-tool counts weigh by count too (8 events; Write 5, Edit 3)" \
  "$(grep -q '^Gate journal: 8 ask/deny event(s)$' <<<"$out_counted" && grep -qE '^ *5  Write$' <<<"$out_counted" && grep -qE '^ *3  Edit$' <<<"$out_counted" && echo 1 || echo 0)"

EMPTY="$TMPDIR_TEST/empty.jsonl"
: > "$EMPTY"
out_empty="$(MH_GATE_JOURNAL_PATH="$EMPTY" python3 "$REPORT_PY")"
assert "empty journal reports empty, not a divide-by-zero" \
  "$(grep -q '^Gate journal is empty' <<<"$out_empty" && echo 1 || echo 0)"

# GH #337: a shadow rule's would_deny rows are listed per rule with sample commands.
SHADOW="$TMPDIR_TEST/shadow.jsonl"
cat > "$SHADOW" <<'EOF'
{"ts": "2026-10-01T10:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_deny", "session_id": "s1", "rule": "mkfs", "command": "mkfs.ext4 /dev/sdz1"}
{"ts": "2026-10-01T10:01:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_deny", "session_id": "s2", "rule": "mkfs", "command": "mkfs.vfat /dev/sdz2"}
{"ts": "2026-10-01T10:02:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_ask", "session_id": "s2", "rule": "opaque-verb", "command": "$RUNNER build"}
{"ts": "2026-10-01T10:03:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": "s2", "rule": "rm-rf"}
EOF
out_shadow="$(MH_GATE_JOURNAL_PATH="$SHADOW" python3 "$REPORT_PY")"
assert "shadow section lists the mkfs rule with 2 hits over 2 sessions" \
  "$(grep -qE '^ *2  gate:bash:irrecoverable  mkfs  \(2 session\(s\)\)$' <<<"$out_shadow" && echo 1 || echo 0)"
assert "shadow section shows a sample command per rule" \
  "$(grep -qF 'e.g. mkfs.vfat /dev/sdz2' <<<"$out_shadow" && echo 1 || echo 0)"
assert "a would_ask rule is listed too" \
  "$(grep -qE '^ *1  gate:bash:irrecoverable  opaque-verb  \(1 session\(s\)\)$' <<<"$out_shadow" && echo 1 || echo 0)"
assert "an enforced deny with a rule id is not listed as a shadow rule" \
  "$(grep -qE '  rm-rf  \(' <<<"$out_shadow" && echo 0 || echo 1)"
assert "would_* rows are not blocks: 1 deny + 3 shadow rows prints 1 in the headline" \
  "$(grep -q '^Gate journal: 1 ask/deny event(s)$' <<<"$out_shadow" && echo 1 || echo 0)"
assert "would_* rows stay out of the By-tool table (Bash 1, not 4)" \
  "$(grep -qE '^ *1  Bash$' <<<"$(sed -n '/^By tool/,/^$/p' <<<"$out_shadow")" && echo 1 || echo 0)"
ONLY_SHADOW="$TMPDIR_TEST/only-shadow.jsonl"
head -2 "$SHADOW" > "$ONLY_SHADOW"
out_os="$(MH_GATE_JOURNAL_PATH="$ONLY_SHADOW" python3 "$REPORT_PY")"
assert "a journal of only would_* rows still prints the shadow section, not 'empty'" \
  "$(grep -q '^Gate journal: 0 ask/deny event(s)$' <<<"$out_os" && grep -qE '^ *2  gate:bash:irrecoverable  mkfs' <<<"$out_os" && echo 1 || echo 0)"
assert "no shadow section when the journal has no would_* row" \
  "$(grep -q '^Shadow rules' <<<"$out" && echo 0 || echo 1)"

# Session-less rows (no session_id: test fixtures or direct gate runs, not live hook
# calls) must not count. The real journal once held 268,206 of them beside ~800 real rows.
SESSIONLESS="$TMPDIR_TEST/sessionless.jsonl"
cat > "$SESSIONLESS" <<'EOF2'
{"ts": "2026-09-29T01:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": null, "mh_version": null}
{"ts": "2026-09-29T01:00:01Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "mh_version": null}
{"ts": "2026-09-29T01:00:02Z", "id": "gate:bash:subagent-git-guard", "tool_name": "Bash", "decision": "deny", "session_id": null}
{"ts": "2026-10-01T09:00:00Z", "id": "gate:write:test-integrity", "tool_name": "Edit", "decision": "ask", "session_id": "real1"}
EOF2
out_sl="$(MH_GATE_JOURNAL_PATH="$SESSIONLESS" python3 "$REPORT_PY")"
assert "session-less rows are left out of the event total" \
  "$(grep -q '^Gate journal: 1 ask/deny event(s)$' <<<"$out_sl" && echo 1 || echo 0)"
assert "a session-less gate (null or missing session_id) does not appear in the gate table" \
  "$(grep -qE 'irrecoverable|subagent-git-guard' <<<"$(sed -n '/^By gate/,/^By tool/p' <<<"$out_sl")" && echo 0 || echo 1)"
assert "the ignored session-less count is reported, not hidden" \
  "$(grep -q 'Ignored 3 session-less row(s)' <<<"$out_sl" && echo 1 || echo 0)"
assert "range spans only the real row" \
  "$(grep -q '^Range: 2026-10-01T09:00:00Z .. 2026-10-01T09:00:00Z$' <<<"$out_sl" && echo 1 || echo 0)"
ONLY_SL="$TMPDIR_TEST/only-sessionless.jsonl"
head -2 "$SESSIONLESS" > "$ONLY_SL"
out_only="$(MH_GATE_JOURNAL_PATH="$ONLY_SL" python3 "$REPORT_PY")"
assert "a journal of only session-less rows says so instead of printing zero-count tables" \
  "$(grep -q 'no events with a session_id' <<<"$out_only" && grep -q 'Ignored 2 session-less row(s)' <<<"$out_only" && echo 1 || echo 0)"
# The textual fast skip for null-session rows must not change what the full parse decides:
# a compact spelling and a null row carrying "count" both still go through json.loads.
SL_SPELL="$TMPDIR_TEST/sessionless-spellings.jsonl"
printf '%s\n' \
  '{"ts":"2026-09-29T01:00:00Z","id":"gate:a","tool_name":"Bash","decision":"deny","session_id":null}' \
  '{"ts": "2026-09-29T01:00:01Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "allow-suppressed", "session_id": null, "count": 3}' \
  '{"ts": "2026-10-01T09:00:00Z", "id": "gate:b", "tool_name": "Edit", "decision": "ask", "session_id": "real1"}' > "$SL_SPELL"
out_spell="$(MH_GATE_JOURNAL_PATH="$SL_SPELL" python3 "$REPORT_PY")"
assert "compact \"session_id\":null parses as session-less, and a null row's count:3 still weighs (1 + 3 = 4)" \
  "$(grep -q 'Ignored 4 session-less row(s)' <<<"$out_spell" && grep -q '^Gate journal: 1 ask/deny event(s)$' <<<"$out_spell" && echo 1 || echo 0)"

# A made-up id still passes the session_id filter; the report names non-UUID ids (counted, not
# dropped: another host's log may not use UUIDs) so a fixture-heavy gate count is visible.
ODDID="$TMPDIR_TEST/oddid.jsonl"
cat > "$ODDID" <<'JSONL'
{"ts": "2026-10-01T09:00:00Z", "id": "gate:write:test-integrity", "tool_name": "Edit", "decision": "ask", "session_id": "3ee810d0-aa02-40c6-aea7-e8de710cbe92"}
{"ts": "2026-10-01T09:01:00Z", "id": "gate:agent:subagent-verdict-check", "tool_name": "general-purpose", "decision": "deny", "session_id": "test-session"}
{"ts": "2026-10-01T09:02:00Z", "id": "gate:agent:subagent-verdict-check", "tool_name": "general-purpose", "decision": "deny", "session_id": "test-session"}
JSONL
out_odd="$(MH_GATE_JOURNAL_PATH="$ODDID" python3 "$REPORT_PY")"
assert "non-UUID session ids are named with their event count" \
  "$(grep -q 'Non-UUID session id.*test-session x2' <<<"$out_odd" && echo 1 || echo 0)"
assert "non-UUID rows are still counted, not dropped" \
  "$(grep -q '3 ask/deny event' <<<"$out_odd" && echo 1 || echo 0)"

NONOBJ="$TMPDIR_TEST/nonobj.jsonl"
printf '%s\n' '[]' '"str"' '7' '{"ts": "2026-10-01T09:00:00Z", "id": "gate:write:test-integrity", "tool_name": "Edit", "decision": "ask", "session_id": "3ee810d0-aa02-40c6-aea7-e8de710cbe92"}' > "$NONOBJ"
out_nonobj="$(MH_GATE_JOURNAL_PATH="$NONOBJ" python3 "$REPORT_PY" 2>&1)"; rc_nonobj=$?
assert "a valid-JSON row that is not an object is skipped, not a crash" \
  "$([[ $rc_nonobj -eq 0 ]] && grep -q '1 ask/deny event' <<<"$out_nonobj" && echo 1 || echo 0)"

BADTYPES="$TMPDIR_TEST/badtypes.jsonl"
printf '%s\n' \
  '{"ts": 7, "id": ["x"], "tool_name": {"a": 1}, "decision": "ask", "session_id": "3ee810d0-aa02-40c6-aea7-e8de710cbe92"}' \
  '{"ts": "2026-10-01T09:00:00Z", "id": "gate:a", "tool_name": "Bash", "decision": "would_deny", "rule": ["r"], "command": 5, "session_id": "3ee810d0-aa02-40c6-aea7-e8de710cbe92"}' \
  '{"ts": "2026-10-01T09:01:00Z", "id": "gate:a", "tool_name": "Bash", "decision": "ask", "session_id": "3ee810d0-aa02-40c6-aea7-e8de710cbe92"}' > "$BADTYPES"
out_bt="$(MH_GATE_JOURNAL_PATH="$BADTYPES" python3 "$REPORT_PY" 2>&1)"; rc_bt=$?
assert "an object row with wrong-typed fields is counted, not a crash" \
  "$([[ $rc_bt -eq 0 ]] && grep -q '2 ask/deny event' <<<"$out_bt" && echo 1 || echo 0)"

echo
echo "=== $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
