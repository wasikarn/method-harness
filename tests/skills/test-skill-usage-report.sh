#!/usr/bin/env bash
# Regression test for the mh:gate-report skill's second script,
# skills/meta/gate-report/scripts/skill-usage.py (GH #474): which skills had no recorded use in the
# last N sessions of skill-usage.jsonl. Points it at a synthetic log and a synthetic skills tree,
# so it never touches the real ~/.local/share/kbg/metrics/skill-usage.jsonl.
# Run standalone: bash tests/skills/test-skill-usage-report.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
REPORT_PY="$ROOT/skills/meta/gate-report/scripts/skill-usage.py"
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
has() { grep -qF -- "$1" <<<"$2" && echo 1 || echo 0; }

[[ -f "$REPORT_PY" ]] || { echo "FATAL: $REPORT_PY not found" >&2; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'tmp_delete "$TMPDIR_TEST"' EXIT

echo "=== skill-usage report ==="

assert "SKILL.md references scripts/skill-usage.py" "$(has 'scripts/skill-usage.py' "$(cat "$SKILL_MD")")"

# A synthetic plugin tree: alpha never used, beta manual-only never used, gamma used recently, delta used
# only in the oldest session, epsilon manual-only and used.
SK="$TMPDIR_TEST/skills"
mkdir -p "$SK/meta/alpha" "$SK/meta/beta" "$SK/meta/gamma" "$SK/meta/delta" "$SK/meta/epsilon"
printf -- '---\nname: alpha\n---\n' > "$SK/meta/alpha/SKILL.md"
printf -- '---\nname: beta\ndisable-model-invocation: true\n---\n' > "$SK/meta/beta/SKILL.md"
printf -- '---\nname: gamma\n---\n' > "$SK/meta/gamma/SKILL.md"
printf -- '---\nname: delta\n---\n' > "$SK/meta/delta/SKILL.md"
printf -- '---\nname: epsilon\ndisable-model-invocation: true\n---\n' > "$SK/meta/epsilon/SKILL.md"

LOG="$TMPDIR_TEST/skill-usage.jsonl"
cat > "$LOG" <<'EOF'
{"ts":"2026-09-01T10:00:00Z","session_id":"s1","skill":"mh:delta","plugin":"mh"}
{"ts":"2026-09-02T10:00:00Z","session_id":"s2","skill":"mh:gamma","plugin":"mh"}
{"ts":"2026-09-02T10:05:00Z","session_id":"s2","skill":"mattpocock-skills:tdd","plugin":"mattpocock-skills"}
not json at all
{"ts":"2026-09-03T10:00:00Z","session_id":"s3","skill":"mh:epsilon","plugin":"mh","source":"typed"}
{"ts":"2026-09-04T10:00:00Z","session_id":"s4","skill":"mh:gamma","plugin":"mh"}
EOF

out=$(python3 "$REPORT_PY" --log "$LOG" --skills-dir "$SK" --sessions 3 2>&1); rc=$?
assert "exits 0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
assert "header names the window: last 3 of 4 sessions with a skill use" "$(has 'last 3 of 4 sessions' "$out")"
assert "an unused model-invocable skill is listed with 'never'" "$(grep -qE '^  alpha +last use: never' <<<"$out" && echo 1 || echo 0)"
assert "a skill used only before the window is listed with its last-use date" "$(grep -qE '^  delta +last use: 2026-09-01' <<<"$out" && echo 1 || echo 0)"
assert "a skill used inside the window is not listed" "$(grep -qE '^  gamma ' <<<"$out" && echo 0 || echo 1)"
assert "a manual-only skill with no use is listed apart from the model-invocable list" \
  "$(awk '/Manual-only/{f=1} f && /^  beta /{ok=1} END{print ok+0}' <<<"$out")"
assert "an unused manual-only skill is not in the model-invocable section" \
  "$(awk '/Manual-only/{exit} /^  beta /{bad=1} END{print bad ? 0 : 1}' <<<"$out")"
assert "a used manual-only skill is not listed" "$(grep -qE '^  epsilon ' <<<"$out" && echo 0 || echo 1)"
assert "the output says sessions with no skill use are invisible" "$(has 'no skill use' "$out")"
assert "the output says zero use is not broken" "$(has 'not broken' "$out")"

out_all=$(python3 "$REPORT_PY" --log "$LOG" --skills-dir "$SK" --sessions 100 2>&1)
assert "N above the session count uses every session: last 4 of 4" "$(has 'last 4 of 4 sessions' "$out_all")"
assert "with every session in the window delta is no longer listed" "$(grep -qE '^  delta ' <<<"$out_all" && echo 0 || echo 1)"

out_def=$(python3 "$REPORT_PY" --log "$LOG" --skills-dir "$SK" 2>&1)
assert "the default N is 100 sessions" "$(has 'last 4 of 4 sessions' "$out_def")"

out_missing=$(python3 "$REPORT_PY" --log "$TMPDIR_TEST/nope.jsonl" --skills-dir "$SK" 2>&1); rc=$?
assert "a missing log prints 'Skill usage log not set up.' and exits 0" \
  "$([[ $rc -eq 0 ]] && [[ "$out_missing" == "Skill usage log not set up." ]] && echo 1 || echo 0)"

for bad in 0 -1 abc; do
  python3 "$REPORT_PY" --log "$LOG" --skills-dir "$SK" --sessions "$bad" >/dev/null 2>&1; rc=$?
  assert "--sessions $bad is rejected with a non-zero exit" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
done

: > "$TMPDIR_TEST/empty.jsonl"
out_empty=$(python3 "$REPORT_PY" --log "$TMPDIR_TEST/empty.jsonl" --skills-dir "$SK" 2>&1); rc=$?
assert "an empty log says no sessions are logged and exits 0" \
  "$([[ $rc -eq 0 ]] && grep -q 'No skill use logged' <<<"$out_empty" && echo 1 || echo 0)"

# A session that uses a skill again later is recent: s1 first used delta on day 1 and gamma on day 3,
# s2 used only alpha on day 2, so --sessions 1 is s1 (last use day 3) and gamma is not unused.
cat > "$TMPDIR_TEST/returning.jsonl" <<'EOF'
{"ts":"2026-09-01T10:00:00Z","session_id":"s1","skill":"mh:delta","plugin":"mh"}
{"ts":"2026-09-02T10:00:00Z","session_id":"s2","skill":"mh:alpha","plugin":"mh"}
{"ts":"2026-09-03T10:00:00Z","session_id":"s1","skill":"mh:gamma","plugin":"mh"}
EOF
out_ret=$(python3 "$REPORT_PY" --log "$TMPDIR_TEST/returning.jsonl" --skills-dir "$SK" --sessions 1 2>&1)
assert "a session that returned later is the most recent one in the window" \
  "$([[ "$(has 'gamma' "$out_ret")" == 0 && "$(has 'alpha' "$out_ret")" == 1 ]] && echo 1 || echo 0)"

echo
echo "=== $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
