#!/usr/bin/env bash
# Regression test for the mh:cost-report dedup script,
# skills/meta/cost-report/scripts/cost-report-dedup.js (extracted 2026-08-23 from the
# command body's embedded fence — 200-LOC cap refactor; this file now runs the
# real bundled script directly instead of extracting a fence, so there is no
# separate maintained copy to drift from the command). Points it at a
# synthetic HOME so it never touches the real
# ~/.local/share/kbg/metrics/costs.jsonl, and checks the dedup math.
#
# Covers a live bug found 2026-08-07 by an adversarial code-correctness review of
# v0.68.209/210 (docs/research/orchestrator-tax-gap-analysis-2026-08-07.md): the
# dedup key `(r.stream||"")+" "+(r.model||"")` treated a streamless legacy row
# (written before `stream` shipped — always implicitly the orchestrator's own
# total) and a same-model post-fix `stream:"orchestrator"` row as two different
# buckets, so a session_id spanning the upgrade got double-counted. Confirmed live
# against the operator's real costs.jsonl: an $8.07 overcount on one session.
# Fixed by defaulting the missing `stream` to `"orchestrator"` in the dedup key.
#
# Note on what proves what (found by a second-round adversarial review,
# 2026-08-07): the actual proof that these fixtures discriminate the fix from
# the bug is the mutation test: manually reverting `(r.stream||"orchestrator")`
# to `(r.stream||"")` in a scratch copy of skills/meta/cost-report/scripts/
# cost-report-dedup.js and pointing REPORT_JS at it — case 1 then fails with a
# wrong total instead of a crash. That's not automated here (it would require
# mutating the file under test, which this suite intentionally doesn't do);
# re-run it by hand if this test's fixtures are ever revised. (The pre-2026-08-23
# fenced-script version of this recipe mutated a scratch copy of
# skills/meta/cost-report/SKILL.md instead — same mutation, different file.)
# Extended 2026-08-07 for the agent_type breakdown (docs/research/
# orchestrator-tax-gap-analysis-2026-08-07.md, "Re-read audit" G1 follow-up): the
# dedup key widened again, from (session_id, stream, model) to (session_id, stream,
# model, agent_type), for the identical reason `stream` was added to it earlier the
# same day — two agent types spending on the same model would otherwise collide.
# Run standalone: bash tests/skills/test-cost-report.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_JS="$ROOT/skills/meta/cost-report/scripts/cost-report-dedup.js"
SKILL_MD="$ROOT/skills/meta/cost-report/SKILL.md"

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

[[ -f "$REPORT_JS" ]] || { echo "FATAL: $REPORT_JS not found — the cost-report skill's script moved without updating this test" >&2; exit 1; }
[[ -f "$SKILL_MD" ]] || { echo "FATAL: $SKILL_MD not found — the skill moved without updating this test" >&2; exit 1; }

echo "=== cost-report dedup (stream-aware) ==="

# Wiring guard (plan-review finding, 2026-08-23; path changed 2026-09-07): the skill
# body must invoke the script via ${CLAUDE_SKILL_DIR}, set wherever a skill loads
# (harness-audit and memory-lint use the same). The hook-only ${CLAUDE_PLUGIN_ROOT}
# expands EMPTY in a skill body, and MH_PLUGIN_ROOT comes from a SessionStart hook an
# eval sandbox may not run; either would ENOENT for a real user while this suite
# passes green against the repo path. No other gate sees that mismatch, so pin it here.
bad_refs=$(/usr/bin/grep -c 'CLAUDE_PLUGIN_ROOT\|MH_PLUGIN_ROOT' "$SKILL_MD") || true
csd_refs=$(/usr/bin/grep -c 'CLAUDE_SKILL_DIR}/scripts/cost-report-dedup\.js' "$SKILL_MD") || true
[[ "$bad_refs" == "0" && "$csd_refs" -ge 1 ]] && ok=1 || ok=0
assert "SKILL.md invokes cost-report-dedup.js via \${CLAUDE_SKILL_DIR} and never names CLAUDE_PLUGIN_ROOT or MH_PLUGIN_ROOT (got $csd_refs skill-dir refs, $bad_refs bad refs)" "$ok"

# Adversarial case: a session_id with a pre-stream legacy row (model_scoped:true,
# no `stream` field — always meant the orchestrator total) and a post-fix
# orchestrator row for the SAME model, newer timestamp. Must dedup to ONE row
# (the newer one wins), not sum both. The two rows carry DIFFERENT costs ($5.0
# vs $7.0) on purpose — if the dedup key were buggy and summed instead of
# deduping, the total would be $12.0000; if it deduped but picked the wrong
# (older) row, it'd be $5.0000. Only "latest wins, no summing" lands on $7.0000,
# so the assertion pins the exact semantics, not just a plausible-looking number.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-08-01T00:00:00Z","session_id":"upgrade-span","transcript_path":"/t","model":"claude-opus-4-8","model_scoped":true,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":5.0}
{"timestamp":"2026-08-07T00:00:00Z","session_id":"upgrade-span","transcript_path":"/t","model":"claude-opus-4-8","model_scoped":true,"stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":7.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
total=$(printf '%s' "$out" | /usr/bin/grep '^total:' | /usr/bin/grep -oE '\$[0-9.]+' | tr -d '$')
[[ "$rc" == "0" && "$total" == "7.0000" ]] && ok=1 || ok=0
assert "legacy streamless row (\$5) + post-fix orchestrator row (\$7, same session+model) dedup to the NEWER row only, not summed (got total=\$${total:-?}, want \$7.0000)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Positive case: two DIFFERENT streams for the same session+model must NOT
# collide — orchestrator and subagent are genuinely separate spend and both
# should survive dedup and sum.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-08-07T00:00:00Z","session_id":"two-streams","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":3.0}
{"timestamp":"2026-08-07T00:00:01Z","session_id":"two-streams","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","turns":4,"input_tokens":50,"output_tokens":25,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":2.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
total=$(printf '%s' "$out" | /usr/bin/grep '^total:' | /usr/bin/grep -oE '\$[0-9.]+' | tr -d '$')
[[ "$rc" == "0" && "$total" == "5.0000" ]] && ok=1 || ok=0
assert "orchestrator + subagent rows (same session+model, DIFFERENT stream) both survive dedup and sum (got total=\$${total:-?}, want \$5.0000)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Adversarial case (2026-08-07, agent_type breakdown): two subagent rows, same
# session+model+stream, DIFFERENT agent_type. Must NOT collide — a mh:code-reviewer
# dispatch and an Explore dispatch on the same model are different populations of
# work, same reasoning as the stream split above. Differing costs ($4/$6) so only
# "both survive, sum to $10" passes — a buggy dedup key that ignores agent_type
# would drop one and land on $4 or $6 instead.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-08-07T00:00:00Z","session_id":"two-types","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","agent_type":"mh:code-reviewer","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":4.0}
{"timestamp":"2026-08-07T00:00:01Z","session_id":"two-types","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","agent_type":"Explore","turns":4,"input_tokens":50,"output_tokens":25,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":6.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
total=$(printf '%s' "$out" | /usr/bin/grep '^total:' | /usr/bin/grep -oE '\$[0-9.]+' | tr -d '$')
[[ "$rc" == "0" && "$total" == "10.0000" ]] \
  && /usr/bin/grep -q 'By agent type' <<<"$out" \
  && /usr/bin/grep -q 'mh:code-reviewer' <<<"$out" \
  && /usr/bin/grep -q 'Explore' <<<"$out" && ok=1 || ok=0
assert "two subagent rows (same session+model+stream, DIFFERENT agent_type) both survive dedup, sum to \$10, and appear in the By agent type section (got total=\$${total:-?})" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Regression (found live, 2026-08-07, running this exact report against real
# production data): the report's `by()` helper groups over the FULL `latest` array
# regardless of which key function is passed — it does not pre-filter to the rows
# the caller actually cares about. "By stream" already guards this by skipping the
# "(unknown)" bucket when printing; "By agent type" shipped WITHOUT that same guard,
# so every non-subagent row (every orchestrator row, on a real dataset almost the
# whole total) landed in an "(unknown)" line that read as "$38,403 of untyped
# subagent spend" when it was actually "everything that isn't a typed subagent row."
# Pin it: one large orchestrator row (no agent_type) + one small typed subagent row
# + one untyped subagent row. The By agent type section must show the typed row's $2
# and the untyped subagent row as its own "(unknown)" line ($3), never the
# orchestrator's $1000. A "tok" column (input+output) must also be present.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-08-07T00:00:00Z","session_id":"unknown-leak","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":1000.0}
{"timestamp":"2026-08-07T00:00:01Z","session_id":"unknown-leak","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","agent_type":"Explore","turns":1,"input_tokens":5,"output_tokens":2,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":2.0}
{"timestamp":"2026-08-07T00:00:02Z","session_id":"unknown-leak","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","turns":1,"input_tokens":7,"output_tokens":3,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":3.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
agent_section=$(printf '%s' "$out" | awk '/=== By agent type/{f=1;next} /^$/{f=0} f')
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q 'Explore' <<<"$agent_section" \
  && /usr/bin/grep -q '\$2.0000' <<<"$agent_section" \
  && ! /usr/bin/grep -q '1000' <<<"$agent_section" \
  && /usr/bin/grep -q '\$3.0000.*(unknown)$' <<<"$agent_section" \
  && /usr/bin/grep -qE '\b7 tok  Explore$' <<<"$agent_section" \
  && [[ "$(printf '%s\n' "$agent_section" | /usr/bin/grep -oE '\(unknown\)|Explore' | tr '\n' ' ')" == "(unknown) Explore " ]] && ok=1 || ok=0
assert "By agent type shows the typed subagent row's \$2.0000 and the untyped subagent row as its own \$3.0000 (unknown) line, never the orchestrator's \$1000, with a tok column, ranked by cost desc ((unknown) \$3 above Explore \$2 despite reverse insertion order)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Era notes (2026-09-07): a row without dedup_usage was summed per JSONL line, so its
# cost is inflated too, not just turns/tokens — the note must say so, or a reader
# trusts the legacy total. A dedup_usage row without usage_pick:"last" gets the
# output-low note. A row carrying both gets neither. Three rows, three sessions,
# so all three states show in one run; the counts pin which rows triggered which note.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-08-07T00:00:00Z","session_id":"legacy","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-09-04T00:00:00Z","session_id":"first-line","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-09-05T00:00:00Z","session_id":"modern","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '^note: 1 of 3 rows predate dedup_usage.*turns, tokens, and cost run ~2.4x high' <<<"$out" \
  && /usr/bin/grep -q '^note: 1 of 3 rows predate usage_pick.*output_tokens (and cost) run ~39% low' <<<"$out" && ok=1 || ok=0
assert "era notes: the pre-dedup row's note names cost as inflated, the first-line row gets the output-low note, and the modern row triggers neither (1 of 3 each)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Third era note (deep-audit F7, 2026-09-25): a pre-#162 row with real cache-write
# tokens but no cache_write_tokens_1h field at all must be flagged as likely
# undercounting cost; a post-#162 row with genuinely zero 1h writes (field present,
# set to 0) must NOT trigger it -- the discriminator is field presence, not value.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-01T00:00:00Z","session_id":"pre-ttl-split","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":1000,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":2.5}
{"timestamp":"2026-09-25T00:00:01Z","session_id":"post-ttl-split","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":0.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '^note: 1 of 2 rows predate the 1h/5m cache-write split' <<<"$out" && ok=1 || ok=0
assert "third era note fires once for the pre-#162 row with real cache writes, not for the post-#162 zero-1h row" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Fourth era note (issue #163, mh:blind-spot-hunter follow-up on #162): a
# claude-opus-5-5 row from before 1.1.116 carries the wrong (Opus 5) rate
# despite rate_verified:true, and must be flagged. A post-1.1.116 opus-5-5
# row, a pre-1.1.116 row on a DIFFERENT model, and a row with no mh_version at
# all must not trigger it -- version compared numerically ("1.1.9" < "1.1.10").
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-23T00:00:00Z","session_id":"stale-opus","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"mh_version":"1.1.9","estimated_cost_usd":5.0}
{"timestamp":"2026-09-25T00:00:00Z","session_id":"fixed-opus","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"mh_version":"1.1.116","estimated_cost_usd":4.0}
{"timestamp":"2026-09-23T00:00:01Z","session_id":"pre116-sonnet","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"mh_version":"1.1.9","estimated_cost_usd":2.0}
{"timestamp":"2026-08-01T00:00:00Z","session_id":"no-version","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":3.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '^note: 1 of 4 rows are claude-opus-5-5 from before the missing rate-table branch' <<<"$out" && ok=1 || ok=0
assert "fourth era note fires once for the pre-1.1.116 opus-5-5 row only, not the fixed opus-5-5 row, the pre-1.1.116 sonnet row, or the version-less row (1.1.9 < 1.1.116 compared numerically, not lexically)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# MH_COSTS_FILE override (2026-09-07): evals run in a fresh HOME and can only plant a
# fixture in the workspace, so the env path must win over the HOME default. HOME points
# at a dir with NO log; only the override path can produce the $1.0000 total.
fake_home=$(mktemp -d)
cat > "$fake_home/planted.jsonl" <<'EOF'
{"timestamp":"2026-09-05T00:00:00Z","session_id":"override","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
EOF
out=$(HOME="$fake_home" MH_COSTS_FILE="$fake_home/planted.jsonl" node "$REPORT_JS" 2>&1)
rc=$?
total=$(printf '%s' "$out" | /usr/bin/grep '^total:' | /usr/bin/grep -oE '\$[0-9.]+' | tr -d '$')
[[ "$rc" == "0" && "$total" == "1.0000" ]] && ok=1 || ok=0
assert "MH_COSTS_FILE overrides the HOME default (got total=\$${total:-?} from a HOME with no log)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Modern-only data prints no era note at all.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-05T00:00:00Z","session_id":"modern","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] && ! /usr/bin/grep -q '^note:' <<<"$out" && ok=1 || ok=0
assert "modern-only data prints no era note" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Handoff cost (restored 2026-09-20): rows carrying verify_per_return render the section
# (returns per orchestrator turn, then one combined "all subagents" median/p90/count line,
# no role breakdown). A legacy row without the field is skipped there, never a crash.
# subagent windows [100,300,500] -> med 300, p90 500.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-20T00:00:00Z","session_id":"hv","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":10,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"returns":3,"verify_tokens":900,"verify_cache_read":0,"verify_per_return":[100,300,500],"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-09-20T00:00:01Z","session_id":"hv","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"subagent","agent_type":"general-purpose","turns":2,"input_tokens":10,"output_tokens":5,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"returns":3,"verify_tokens":900,"verify_cache_read":0,"verify_per_return":[100,300,500],"rate_verified":true,"estimated_cost_usd":2.0}
{"timestamp":"2026-08-07T00:00:01Z","session_id":"legacy","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"stream":"subagent","agent_type":"Explore","turns":1,"input_tokens":5,"output_tokens":2,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"rate_verified":true,"estimated_cost_usd":3.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
hv_section=$(printf '%s' "$out" | awk '/=== Handoff cost/{f=1;next} /^$/{f=0} f')
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '^total:     \$6.0000' <<<"$out" \
  && /usr/bin/grep -q 'returns per orchestrator turn: 0.30' <<<"$hv_section" \
  && /usr/bin/grep -qE '300 med +500 p90 +3 returns  all subagents$' <<<"$hv_section" \
  && ! /usr/bin/grep -qi 'untagged\|(unknown)' <<<"$hv_section" && ok=1 || ok=0
assert "Handoff cost section: returns/turn 0.30, all-subagents med 300 p90 500 over 3 returns; legacy row without verify_per_return skipped, total still \$6" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Restored fields don't duplicate or corrupt existing rows: a plain row with no
# verify_per_return still dedups/sums exactly as before the restore (no Handoff section
# appears, cost total unaffected by the absent fields).
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-05T00:00:00Z","session_id":"plain","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":2,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.5}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
total=$(printf '%s' "$out" | /usr/bin/grep '^total:' | /usr/bin/grep -oE '\$[0-9.]+' | tr -d '$')
[[ "$rc" == "0" && "$total" == "1.5000" ]] && ! /usr/bin/grep -q '=== Handoff cost' <<<"$out" && ok=1 || ok=0
assert "row without verify_per_return: no Handoff section, total unaffected by the restored fields (got total=\$${total:-?})" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# (2026-09-21) jq_failed sentinel rows: cost-tracker.sh emits {error:"jq_failed"} when its
# jq pass dies. The report used to push a sentinel-only session as a $0 row and count it
# as a session. Now: one warning line per session naming the count and the id prefix,
# and the sentinel never reaches `latest`.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-21T00:00:00Z","session_id":"deadbeef-cafe-4000-8000-000000000001","transcript_path":"/t","stream":"orchestrator","error":"jq_failed","files":"/t"}
{"timestamp":"2026-09-21T00:00:01Z","session_id":"deadbeef-cafe-4000-8000-000000000001","transcript_path":"/t","stream":"subagent","error":"jq_failed","files":"/t/a"}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '^warning: 2 jq_failed sentinel rows for session deadbeef' <<<"$out" \
  && /usr/bin/grep -q '^total:     \$0.0000  (0 sessions)' <<<"$out" && ok=1 || ok=0
assert "sentinel-only session prints one warning (count 2, id prefix) and is not counted as a \$0 session (0 sessions)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# (2026-09-21) returns per orchestrator turn: a zero-return orchestrator row (returns:0,
# verify_per_return:[] -- the shape the H8 negative test proves cost-tracker emits) must
# stay in the denominator. 2 returns/10 turns + 0 returns/10 turns = 0.10, not 0.20.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-21T00:00:00Z","session_id":"busy","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":10,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"returns":2,"verify_tokens":400,"verify_cache_read":0,"verify_per_return":[100,300],"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-09-21T00:00:01Z","session_id":"quiet","transcript_path":"/t","model":"claude-sonnet-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":10,"input_tokens":100,"output_tokens":50,"cache_write_tokens":0,"cache_read_tokens":0,"cache_read_per_turn":0,"returns":0,"verify_tokens":null,"verify_cache_read":null,"verify_per_return":[],"rate_verified":true,"estimated_cost_usd":1.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] && /usr/bin/grep -q 'returns per orchestrator turn: 0.10  (2 returns / 20 turns)' <<<"$out" && ok=1 || ok=0
assert "returns per orchestrator turn counts a zero-return orchestrator row's turns in the denominator (2/20 = 0.10)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Missing file: the script itself reports the tracker as not set up (exit 0), so the
# skill body need not pre-check the path — the eval clean case relies on this message.
fake_home=$(mktemp -d)
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
[[ "$rc" == "0" ]] && /usr/bin/grep -q '^Cost tracker not set up:' <<<"$out" && ok=1 || ok=0
assert "missing costs.jsonl prints the 'Cost tracker not set up' line and exits 0" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# CSV export column (deep-audit finding, 2026-09-25, issue #162): the 1h/5m cache-write
# split cost-tracker.sh now writes must reach the CSV, not just the raw JSONL, or the
# per-row token breakdown silently drops the 1h portion while estimated_cost_usd (not
# derived from these columns) stays correct -- masking the gap instead of showing it.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-09-25T00:00:00Z","session_id":"cw1h-csv","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":0,"output_tokens":0,"cache_write_tokens":100,"cache_write_tokens_1h":900,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":7.7}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" csv 2>&1)
rc=$?
header="$(printf '%s\n' "$out" | head -1)"
row="$(printf '%s\n' "$out" | tail -1)"
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q 'cache_write_tokens_1h' <<<"$header" \
  && /usr/bin/grep -q ',100,900,' <<<"$row" && ok=1 || ok=0
assert "csv mode's header and row both carry cache_write_tokens_1h (100 5m, 900 1h)" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Ledger cross-check (GH #334): cost-ledger.jsonl, written by hooks/mod/cost-ledger.ts beside
# costs.jsonl, holds Claude Code's own cumulative ledger (`usd`) per main-loop turn. The report
# recomputes each session's ledger total from the `usd` sequence in file order (a drop restarts
# the count) and never trusts the stored `delta`, which a module reload resets. Fixture: usd
# 2, 6, 7 (a reload: stored delta 7), 1 (a new process: reset), 4, 4 (no spend) -> 2+4+1+1+3+0
# = $11. Wrong answers differ: summed stored deltas $17, last usd $4, max usd $7, summed usd $24,
# an unchanged reading taken as a reset $15. Transcript
# side: the deduped latest rows of the same session, $7 + $1 = $8, so the gap is $3 (27.3%).
# An error row and a non-JSON line are skipped; the error row is counted in a warning.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-10-02T00:00:00Z","session_id":"led-a","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":5.0}
{"timestamp":"2026-10-02T00:00:09Z","session_id":"led-a","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"orchestrator","turns":2,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":7.0}
{"timestamp":"2026-10-02T00:00:09Z","session_id":"led-a","transcript_path":"/t","model":"claude-haiku-4-5","model_scoped":true,"dedup_usage":true,"usage_pick":"last","stream":"subagent","agent_type":"Explore","turns":2,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
EOF
cat > "$metrics_dir/cost-ledger.jsonl" <<'EOF'
{"t":"2026-10-02T00:00:01Z","session_id":"led-a","turn_id":"t1","usd":2,"delta":2,"reset":false}
{"t":"2026-10-02T00:00:02Z","session_id":"led-a","turn_id":"t2","usd":6,"delta":4,"reset":false}
{"t":"2026-10-02T00:00:03Z","session_id":"led-a","turn_id":"t3","error":"HooksError: no implementation for session.usage"}
not json
{"t":"2026-10-02T00:00:04Z","session_id":"led-a","turn_id":"t4","usd":7,"delta":7,"reset":false}
{"t":"2026-10-02T00:00:05Z","session_id":"led-a","turn_id":"t5","usd":1,"delta":1,"reset":true}
{"t":"2026-10-02T00:00:06Z","session_id":"led-a","turn_id":"t6","usd":4,"delta":3,"reset":false}
{"t":"2026-10-02T00:00:07Z","session_id":"led-a","turn_id":"t7","usd":4,"delta":0,"reset":false}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | /usr/bin/grep '^ledger cross-check:')
[[ "$rc" == "0" && "$line" == 'ledger cross-check: transcript $8.0000 vs ledger $11.0000 over 1 sessions; unattributed $3.0000 (27.3% of ledger)' ]] && ok=1 || ok=0
assert "cross-check recomputes the ledger from the usd sequence across a reload and a reset (\$11), against the deduped transcript total (\$8) (got: ${line:-none})" "$ok"
/usr/bin/grep -q '^warning: 1 cost-ledger error rows' <<<"$out" && ok=1 || ok=0
assert "a cost-ledger error row is left out of the ledger total and counted in a warning line" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Data absent: no cost-ledger.jsonl beside costs.jsonl (modules off, an older CLI, no turn yet)
# must say so, not print zero or crash. A ledger file holding only error rows is the same.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-10-02T00:00:00Z","session_id":"led-none","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":5.0}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | /usr/bin/grep '^ledger cross-check:')
[[ "$rc" == "0" && "$line" == 'ledger cross-check: no ledger data'* ]] && ok=1 || ok=0
assert "no cost-ledger.jsonl prints 'ledger cross-check: no ledger data' and exits 0 (got: ${line:-none})" "$ok"
printf '%s\n' '{"t":"2026-10-02T00:00:01Z","session_id":"led-none","turn_id":"t1","error":"x"}' > "$metrics_dir/cost-ledger.jsonl"
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
line=$(printf '%s\n' "$out" | /usr/bin/grep '^ledger cross-check:')
[[ "$line" == 'ledger cross-check: no ledger data'* ]] && ok=1 || ok=0
assert "a cost-ledger.jsonl with only error rows also reads 'no ledger data' (got: ${line:-none})" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Partial: led-p has both sides, led-t only transcript rows (ended before the module loaded),
# led-l only ledger rows (Stop never ran). Only led-p is compared ($5 vs $6); the others are
# counted, not added, so the gap is not inflated by $4 or deflated by $9.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-10-02T00:00:00Z","session_id":"led-p","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":5.0}
{"timestamp":"2026-10-02T00:00:00Z","session_id":"led-t","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":9.0}
EOF
cat > "$metrics_dir/cost-ledger.jsonl" <<'EOF'
{"t":"2026-10-02T00:00:01Z","session_id":"led-p","turn_id":"t1","usd":6,"delta":6,"reset":false}
{"t":"2026-10-02T00:00:01Z","session_id":"led-l","turn_id":"t1","usd":4,"delta":4,"reset":false}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | /usr/bin/grep '^ledger cross-check:')
[[ "$rc" == "0" && "$line" == 'ledger cross-check: transcript $5.0000 vs ledger $6.0000 over 1 sessions; unattributed $1.0000 (16.7% of ledger); left out: 1 transcript-only, 1 ledger-only' ]] && ok=1 || ok=0
assert "partial data compares only sessions on both sides and counts the rest (got: ${line:-none})" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# A `usd` that is not a finite number (null is what JSON.stringify writes for NaN/Infinity; "",
# a numeric string, a missing key) is skipped and counted, never read as $0. As $0 it is a reset,
# so the next 1.5 is added whole: rows 1, null, "", "1.2", (none), 1.5 then read $2.50, not $1.50.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-10-02T00:00:00Z","session_id":"led-nf","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.5}
EOF
cat > "$metrics_dir/cost-ledger.jsonl" <<'EOF'
{"t":"2026-10-02T00:00:01Z","session_id":"led-nf","turn_id":"t1","usd":1,"delta":1,"reset":false}
{"t":"2026-10-02T00:00:02Z","session_id":"led-nf","turn_id":"t2","usd":null,"delta":null,"reset":true}
{"t":"2026-10-02T00:00:03Z","session_id":"led-nf","turn_id":"t3","usd":""}
{"t":"2026-10-02T00:00:04Z","session_id":"led-nf","turn_id":"t4","usd":"1.2"}
{"t":"2026-10-02T00:00:05Z","session_id":"led-nf","turn_id":"t5"}
{"t":"2026-10-02T00:00:06Z","session_id":"led-nf","turn_id":"t6","usd":1.5,"delta":1.5,"reset":true}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | /usr/bin/grep '^ledger cross-check:')
[[ "$rc" == "0" && "$line" == 'ledger cross-check: transcript $1.5000 vs ledger $1.5000 over 1 sessions; unattributed $0.0000 (0.0% of ledger)' ]] && ok=1 || ok=0
assert "a null, empty, string or missing usd is skipped, not read as a \$0 reset (\$1.50, not \$2.50) (got: ${line:-none})" "$ok"
/usr/bin/grep -q '^warning: 4 cost-ledger rows with no finite usd were skipped' <<<"$out" && ok=1 || ok=0
assert "the skipped non-finite usd rows are counted in a warning line" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

# Load markers (GH #444): the module writes one `loaded` row per session (per module load) to
# cost-ledger.jsonl, so a session with spend and no marker ran with modules off. The rate counts
# only sessions whose last costs row is at or after the first marker (older sessions predate the
# marker). Fixture: led-old predates it, mk-a has a marker (twice: a reload), mk-b has none ->
# 1 of 2. A marker row has no usd and must not trip the no-finite-usd warning. A marker-only file
# still reads "no ledger data" for the cross-check.
fake_home=$(mktemp -d)
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
cat > "$metrics_dir/costs.jsonl" <<'EOF'
{"timestamp":"2026-10-01T00:00:00Z","session_id":"led-old","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-10-03T00:00:10Z","session_id":"mk-a","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
{"timestamp":"2026-10-03T00:00:20Z","session_id":"mk-b","transcript_path":"/t","model":"claude-opus-5-5","model_scoped":true,"stream":"orchestrator","turns":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":0,"cache_write_tokens_1h":0,"cache_read_tokens":0,"rate_verified":true,"estimated_cost_usd":1.0}
EOF
cat > "$metrics_dir/cost-ledger.jsonl" <<'EOF'
{"t":"2026-10-03T00:00:00Z","session_id":"mk-a","loaded":true,"cli":"2.1.289","mh":"1.1.175"}
{"t":"2026-10-03T00:00:05Z","session_id":"mk-a","loaded":true,"cli":"2.1.289","mh":"1.1.175"}
EOF
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | /usr/bin/grep '^module loaded:')
[[ "$rc" == "0" && "$line" == 'module loaded: 1 of 2 sessions since the first load marker'* ]] && ok=1 || ok=0
assert "module loaded counts sessions with a load marker over sessions since the first marker (got: ${line:-none})" "$ok"
/usr/bin/grep -q 'no finite usd' <<<"$out" && ok=0 || ok=1
assert "a load marker row is not counted as a row with no finite usd" "$ok"
/usr/bin/grep -q '^ledger cross-check: no ledger data' <<<"$out" && ok=1 || ok=0
assert "a marker-only ledger file still reads 'no ledger data' for the cross-check" "$ok"
# No marker at all (modules off since the module change, or an older mh): say so, never 0 of N.
printf '%s\n' '{"t":"2026-10-03T00:00:01Z","session_id":"mk-a","turn_id":"t1","usd":1,"delta":1,"reset":false}' > "$metrics_dir/cost-ledger.jsonl"
out=$(HOME="$fake_home" node "$REPORT_JS" 2>&1)
line=$(printf '%s\n' "$out" | /usr/bin/grep '^module loaded:')
[[ "$line" == 'module loaded: no load marker'* ]] && ok=1 || ok=0
assert "no load marker prints 'module loaded: no load marker' (got: ${line:-none})" "$ok"
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" || true

echo ""
total_t=$((pass + fail))
echo "=== $pass/$total_t passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
