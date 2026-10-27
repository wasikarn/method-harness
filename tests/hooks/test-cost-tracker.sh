#!/usr/bin/env bash
# Tests for hooks/stop/cost-tracker.sh's pricing.
#
# Phase 1 -- rate() model-pricing table. Extracts the live `def rate: ...
# end;` block from the script (so the model branches this test checks can't
# drift out of sync with the real function) and asserts each model-family
# test matches only its own family, not a broader sibling whose name it
# contains (e.g. "opus-5-5" must not fall through to "opus"). $sonnet_rate
# below is a fixed stand-in value the rate def expects as an argument, not a
# pasted copy of a checked branch.
#
# Phase 2 -- group_and_price()'s cache-write pricing (issue #162). Runs the
# real script end to end against a synthetic transcript, so it exercises the
# 5m/1h split as it actually executes, not a re-derived jq snippet.
#
# Run standalone: bash tests/hooks/test-cost-tracker.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/hooks/stop/cost-tracker.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

rate_def="$(sed -n '/^    def rate:/,/end;$/p' "$SCRIPT")"
if [[ -z "$rate_def" ]]; then
  bad "could not extract 'def rate: ... end;' from $SCRIPT — has it been restructured?"
  echo "1 passed, $fail failed"; exit 1
fi

price() {
  local model="$1"
  jq -n --argjson sonnet_rate '{"i":2.0,"o":10.0,"cw":2.50,"cw1h":4.00,"cr":0.20}' --arg m "$model" \
    "$rate_def"$'\n'"{model: \$m} | rate"
}

result="$(price claude-opus-5-5)"
i="$(jq -r .i <<<"$result")"
o="$(jq -r .o <<<"$result")"
cr="$(jq -r .cr <<<"$result")"
v="$(jq -r .v <<<"$result")"
if [[ "$i" == "4.0" && "$o" == "20.0" && "$cr" == "0.20" && "$v" == "true" ]]; then
  ok "claude-opus-5-5 prices at 4.0/20.0, cr=0.20, v=true (Opus 5.5 rate), not Opus 5's 5.0/25.0"
else
  bad "claude-opus-5-5 priced at i=$i o=$o cr=$cr v=$v, expected i=4.0 o=20.0 cr=0.20 v=true — Opus 5.5 branch missing, wrong, or still unverified"
fi

result="$(price claude-opus-5)"
i="$(jq -r .i <<<"$result")"
if [[ "$i" == "5.0" ]]; then
  ok "claude-opus-5 (not 5.5) still prices at 5.0 — the opus-5-5 branch didn't swallow the bare opus test"
else
  bad "claude-opus-5 priced at i=$i, expected i=5.0 — opus-5-5 branch is too broad"
fi

result="$(price claude-haiku-5-5)"
i="$(jq -r .i <<<"$result")"; o="$(jq -r .o <<<"$result")"; cr="$(jq -r .cr <<<"$result")"
if [[ "$i" == "0.10" && "$o" == "0.50" && "$cr" == "0.01" ]]; then
  ok "claude-haiku-5-5 prices at 0.10/0.50, cr=0.01 (prompts up to 100k), not Haiku 4.5's 1.00/5.00"
else
  bad "claude-haiku-5-5 priced at i=$i o=$o cr=$cr, expected i=0.1 o=0.5 cr=0.01 — Haiku 5.5 branch missing or wrong"
fi

result="$(price claude-haiku-4-5)"
i="$(jq -r .i <<<"$result")"
if [[ "$i" == "1.00" ]]; then
  ok "claude-haiku-4-5 still prices at 1.00 — the haiku-5-5 branch didn't swallow the bare haiku test"
else
  bad "claude-haiku-4-5 priced at i=$i, expected i=1.0 — haiku-5-5 branch is too broad"
fi

# 1-hour cache-write rate (issue #162): every model's 1h cache write is priced
# at 2x its base input rate on the live pricing page (confirmed 2026-09-25),
# distinct from and higher than the 5-minute write rate (1.25x). rate() must
# expose it as cw1h so group_and_price can bill 1h-TTL writes correctly.
result="$(price claude-opus-5-5)"
cw="$(jq -r .cw <<<"$result")"
cw1h="$(jq -r .cw1h <<<"$result")"
if [[ "$cw" == "5.00" && "$cw1h" == "8.00" ]]; then
  ok "claude-opus-5-5 exposes cw=5.00 (5m) and cw1h=8.00 (1h), distinct rates"
else
  bad "claude-opus-5-5 cw=$cw cw1h=$cw1h, expected cw=5.00 cw1h=8.00 — 1h cache-write rate missing or wrong"
fi

echo "$pass passed, $fail failed (phase 1)"

echo "=== group_and_price: bills 1h-TTL cache writes at the 1h rate, not the 5m rate ==="

pass2=0
fail2=0
ok2()  { pass2=$((pass2 + 1)); echo "PASS: $1"; }
bad2() { fail2=$((fail2 + 1)); echo "FAIL: $1" >&2; }

# make_usage_line <cache_creation_input_tokens> [ephemeral_5m] [ephemeral_1h]
# Omitting the last two args reproduces a pre-breakdown transcript: only the
# flat field, no `cache_creation` object at all.
make_usage_line() {
  python3 -c '
import json, sys
flat = sys.argv[1]
e5m = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "" else None
e1h = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "" else None
usage = {"input_tokens": 0, "output_tokens": 0,
         "cache_creation_input_tokens": int(flat), "cache_read_input_tokens": 0}
if e5m is not None:
    usage["cache_creation"] = {"ephemeral_5m_input_tokens": int(e5m), "ephemeral_1h_input_tokens": int(e1h)}
print(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": usage}}))
' "$1" "${2-}" "${3-}"
}

run_row() {
  local transcript payload fake_home row
  fake_home=$(mktemp -d)
  transcript=$(mktemp)
  cat > "$transcript"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t162"}))' "$transcript")
  printf '%s' "$payload" | HOME="$fake_home" MH_COST_TRACKER_SETTLE_S=0 bash "$SCRIPT" >/dev/null 2>/dev/null
  row=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null)
  python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" "$transcript" || true
  printf '%s' "$row"
}

# All-1h write: 1,000,000 tokens, entirely ephemeral_1h. Opus 5.5's cw1h rate
# is $8/MTok vs cw (5m) $5/MTok -- expect 8.0, not 5.0.
row="$(make_usage_line 1000000 0 1000000 | run_row)"
cost="$(jq -r .estimated_cost_usd <<<"$row" 2>/dev/null)"
if [[ "$cost" == "8" || "$cost" == "8.0" ]]; then
  ok2 "1,000,000 all-1h cache-write tokens bill at \$8/MTok (1h rate) = \$8.00"
else
  bad2 "1,000,000 all-1h cache-write tokens billed \$$cost, expected \$8.00 -- still using the 5m rate (\$5.00) or wrong"
fi

# Legacy shape (no `cache_creation` breakdown object at all): must still bill
# the full flat total at the 5m rate, unchanged from before this fix.
row="$(make_usage_line 1000000 | run_row)"
cost="$(jq -r .estimated_cost_usd <<<"$row" 2>/dev/null)"
if [[ "$cost" == "5" || "$cost" == "5.0" ]]; then
  ok2 "legacy transcript with only the flat field still bills \$5/MTok (5m rate), unchanged"
else
  bad2 "legacy flat-field-only transcript billed \$$cost, expected \$5.00 -- backward-compat fallback broke"
fi

# Multi-iteration turn (deep-audit finding, 2026-09-25): a real transcript
# line's top-level `cache_creation` object is a copy of iterations[0]'s own
# breakdown, NOT a sum across `.message.usage.iterations[]` -- unlike the
# flat `cache_creation_input_tokens` field, which DOES sum across iterations
# (confirmed empirically: top-level flat == sum(iteration flats) in 2571/2604
# real mismatched lines on this machine; top-level breakdown == sum(iteration
# breakdowns) in only 23/2604). Reading the top-level breakdown directly
# undercounts any multi-iteration turn. Shape below is a real observed line
# (model claude-sonnet-5, iterations [message, advisor_message on
# claude-opus-5, message] -- mh:blind-spot-hunter F8: an earlier draft of
# this fixture mislabeled it "agentic tool-loop" and stripped type/model,
# which is why the F5 case below went unnoticed the first time), values
# otherwise unchanged. Correct total: 3029 (5m) + 429 (1h) = 3458, matching
# the flat field; the bug would instead report 0 (5m) + 429 (1h) = 429,
# dropping iteration[2]'s 3029 5m tokens entirely.
multi_iter_line="$(python3 -c '
import json
iters = [
    {"type": "message", "input_tokens": 2, "output_tokens": 1662, "cache_creation_input_tokens": 429,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 429}},
    {"type": "advisor_message", "model": "claude-opus-5", "input_tokens": 125077, "output_tokens": 3808,
     "cache_creation_input_tokens": 0,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}},
    {"type": "message", "input_tokens": 2, "output_tokens": 401, "cache_creation_input_tokens": 3029,
     "cache_creation": {"ephemeral_5m_input_tokens": 3029, "ephemeral_1h_input_tokens": 0}},
]
usage = {"input_tokens": 4, "output_tokens": 2063, "cache_read_input_tokens": 0,
          "cache_creation_input_tokens": 3458,
          "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 429},
          "iterations": iters}
print(json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-5", "id": "msg_multi1", "usage": usage}}))
')"
row="$(printf '%s\n' "$multi_iter_line" | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
if [[ "$cw" == "3029" && "$cw1h" == "429" ]]; then
  ok2 "multi-iteration turn sums cache-write breakdown across iterations: cw=3029 cw1h=429 (total 3458, matches the flat field)"
else
  bad2 "multi-iteration turn gave cw=$cw cw1h=$cw1h, expected cw=3029 cw1h=429 -- top-level breakdown (iteration[0] only) used instead of summing across iterations"
fi

# F3 (mh:blind-spot-hunter, round 2): an iteration with cache-write tokens
# but no `cache_creation` breakdown object at all (0 real occurrences, but
# the map's own `// 0` would silently treat it as zero on both cw and cw1h
# with no flat-anchored floor). Top-level flat is the only place these
# tokens are visible; the row must not vanish.
row="$(python3 -c '
import json
iters = [{"type": "message", "input_tokens": 2, "output_tokens": 5, "cache_creation_input_tokens": 1000000}]
usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
          "cache_creation_input_tokens": 1000000, "iterations": iters}
print(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "msg_nobreak1", "usage": usage}}))
' | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
if [[ "$cw" == "1000000" && "$cw1h" == "0" ]]; then
  ok2 "an iteration missing cache_creation entirely still anchors to the top-level flat (cw=1000000), row not dropped"
else
  bad2 "iteration-missing-breakdown case gave cw=$cw cw1h=$cw1h (row=$row), expected cw=1000000 cw1h=0 -- the whole turn's cost went missing"
fi

# F4 (mh:blind-spot-hunter, round 2): Claude Code's background-session
# transcripts copy one message.id across sibling files with every
# top-level counter zeroed on the copies except iterations/cache_creation.
# Summing iterations directly would manufacture real dollars on an
# all-zero row (measured on this machine: 17 real records, +55,743
# tokens); anchoring to the (zero) top-level flat must suppress it.
row="$(python3 -c '
import json
iters = [{"type": "message", "input_tokens": 4, "output_tokens": 209, "cache_creation_input_tokens": 209,
          "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 209}}]
usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
          "cache_creation_input_tokens": 0, "iterations": iters}
print(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "msg_bgcopy1", "usage": usage}}))
' | run_row)"
if [[ -z "$row" ]]; then
  ok2 "a zeroed background-session duplicate copy (real top-level flat=0, iterations nonzero) writes no row at all"
else
  bad2 "zeroed-duplicate-copy case wrote a row when it should have written none: $row"
fi

# F5 (mh:blind-spot-hunter, round 2): an advisor_message iteration bills a
# different model than the turn's primary model. If it carries real
# cache-write tokens (0 real occurrences observed, but the mechanism is
# untested without this), summing it in unfiltered could attribute that
# spend to the wrong row. The flat anchor bounds the damage to "no more
# than the executor's own real total, split may skew" rather than adding
# dollars that were never really billed to this row.
row="$(python3 -c '
import json
iters = [
    {"type": "message", "input_tokens": 2, "output_tokens": 5, "cache_creation_input_tokens": 100,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 100}},
    {"type": "advisor_message", "model": "claude-opus-5", "input_tokens": 2, "output_tokens": 5,
     "cache_creation_input_tokens": 900,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 900}},
]
usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
          "cache_creation_input_tokens": 100, "iterations": iters}
print(json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-5", "id": "msg_advisor1", "usage": usage}}))
' | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
if [[ "$cw" == "0" && "$cw1h" == "100" ]]; then
  ok2 "an advisor iteration on a different model cannot push this row's total above its own top-level flat (cw+cw1h=100, not 1000)"
else
  bad2 "advisor-contamination case gave cw=$cw cw1h=$cw1h, expected cw=0 cw1h=100 (total capped at flat=100, not the raw iteration sum of 1000)"
fi

# Remainder-drop bug (issue #163, mh:blind-spot-hunter on #162): a single-iteration
# turn whose cache_creation breakdown doesn't sum to the flat field must not
# silently drop the gap (the #162 comment cited this as 0.55% of 23,484 measured
# messages, ~603K tokens; a direct scan of 118,591 real local lines found zero --
# see hooks/stop/cost-tracker.sh's own comment. Closed defensively regardless).
# flat=1,000,000, e5m=400,000, e1h=590,000 -- 10,000 tokens unaccounted for. The
# fix floors cw1h at flat and derives cw as the remainder, so cw+cw1h always
# equals flat: cw=410,000, cw1h=590,000, cost=(410000*5.00+590000*8.00)/1e6=6.77.
# Pre-fix, cw=e5m=400,000 (the remainder silently dropped), cost=6.72.
row="$(make_usage_line 1000000 400000 590000 | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
cost="$(jq -r .estimated_cost_usd <<<"$row" 2>/dev/null)"
if [[ "$cw" == "410000" && "$cw1h" == "590000" && "$cost" == "6.77" ]]; then
  ok2 "flat != e5m+e1h: the 10,000-token remainder is priced at the 5m rate, not dropped (cw=410000 cw1h=590000 cost=\$6.77)"
else
  bad2 "flat != e5m+e1h gave cw=$cw cw1h=$cw1h cost=\$$cost, expected cw=410000 cw1h=590000 cost=\$6.77 -- remainder silently dropped"
fi

# Same bug, no remainder: flat == e5m+e1h exactly (the shape every real line
# on this machine has). The fix must not perturb this case at all.
row="$(make_usage_line 1000000 400000 600000 | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
if [[ "$cw" == "400000" && "$cw1h" == "600000" ]]; then
  ok2 "flat == e5m+e1h (no remainder): cw=400000 cw1h=600000, unchanged"
else
  bad2 "flat == e5m+e1h gave cw=$cw cw1h=$cw1h, expected cw=400000 cw1h=600000 -- fix perturbed the majority case"
fi

# Floor case (advisor review, 2026-09-25): e1h exceeding flat (not observed on
# this machine, but the API contract for it isn't guaranteed) must not drive
# cw negative -- the fix mirrors the multi-iteration branch's own
# min(e1h, flat) floor, so cw1h caps at flat and cw floors at 0, never a
# negative token count or cost.
row="$(make_usage_line 100 0 900 | run_row)"
cw="$(jq -r .cache_write_tokens <<<"$row" 2>/dev/null)"
cw1h="$(jq -r .cache_write_tokens_1h <<<"$row" 2>/dev/null)"
if [[ "$cw" == "0" && "$cw1h" == "100" ]]; then
  ok2 "e1h > flat (900 > 100): cw1h floors at flat (100), cw floors at 0, never negative"
else
  bad2 "e1h > flat gave cw=$cw cw1h=$cw1h, expected cw=0 cw1h=100 -- no floor, could go negative"
fi

echo "$pass2 passed, $fail2 failed (phase 2)"

# Phase 3 -- late-flush race (GH #329). Failure class: read-before-write race.
# The Stop hook can read the transcript before Claude Code has flushed the
# turn's final response, so the session's last row came up one response short
# (67 of 235 sessions on this machine, 2026-10-02). The hook must wait for the
# transcript to stop growing before it reads. A background writer appends the
# second response 1 s after the hook starts; with a 3 s settle window the row
# must count both. Timing row: a load spike can delay the writer, so one retry
# (same pattern as GH #158).
echo "=== settle: a response flushed after the Stop hook starts is still counted ==="
pass3=0
fail3=0
late_flush_turns() {
  local fake_home transcript payload turns
  fake_home=$(mktemp -d)
  transcript=$(mktemp)
  python3 -c '
import json
u = {"input_tokens": 10, "output_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
print(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "msg_a", "usage": u}}))
' > "$transcript"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t329"}))' "$transcript")
  ( sleep 1; python3 -c '
import json
u = {"input_tokens": 10, "output_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
print(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "msg_b", "usage": u}}))
' >> "$transcript" ) &
  printf '%s' "$payload" | HOME="$fake_home" MH_COST_TRACKER_SETTLE_S=3 bash "$SCRIPT" >/dev/null 2>/dev/null
  wait
  turns=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null | jq -r .turns 2>/dev/null)
  python3 "$ROOT/tests/_lib/tmp_delete.py" "$fake_home" "$transcript" || true
  printf '%s' "$turns"
}
turns="$(late_flush_turns)"
[[ "$turns" == "2" ]] || turns="$(late_flush_turns)"
if [[ "$turns" == "2" ]]; then
  pass3=$((pass3 + 1)); echo "PASS: a response flushed 1 s after the hook started is counted (turns=2)"
else
  fail3=$((fail3 + 1)); echo "FAIL: late-flushed response missed: turns=$turns, expected 2 -- the hook read before the transcript settled" >&2
fi
echo "$pass3 passed, $fail3 failed (phase 3)"

# Phase 4 -- advisor-tool calls are priced (GH #324). Failure class: omitted
# billing component. A response's top-level usage excludes its advisor_message
# iterations (128 of 128 real responses checked), and the flat anchoring above
# rightly keeps them off the executor's row, but nothing priced them at the
# advisor's own model, so ~11% of spend went missing. Each advisor iteration
# must become its own record on the advisor's model, counted once per
# (message.id, iteration) across every file the hook reads, and kept out of
# `turns` and `cache_read_per_turn`.
echo "=== advisor: advisor_message iterations are priced at the advisor's model ==="
pass4=0
fail4=0
ok4()  { pass4=$((pass4 + 1)); echo "PASS: $1"; }
bad4() { fail4=$((fail4 + 1)); echo "FAIL: $1" >&2; }

# adv_line <executor-model> <message-id> [zeroed]
# One executor response with an advisor iteration on claude-fable-5-1
# (1,000,000 in / 10,000 out = $10 + $0.50 = $10.50). The executor's own
# top-level usage is 1000 in / 100 out / 5000 cache read.
adv_line() {
  python3 -c '
import json, sys
model, mid = sys.argv[1], sys.argv[2]
zero = len(sys.argv) > 3
iters = [
    {"type": "message", "input_tokens": 1000, "output_tokens": 100, "cache_read_input_tokens": 5000,
     "cache_creation_input_tokens": 0, "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}},
    {"type": "advisor_message", "model": "claude-fable-5-1", "input_tokens": 1000000, "output_tokens": 10000,
     "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}},
]
top = {"input_tokens": 0 if zero else 1000, "output_tokens": 0 if zero else 100,
       "cache_read_input_tokens": 0 if zero else 5000, "cache_creation_input_tokens": 0, "iterations": iters}
print(json.dumps({"type": "assistant", "message": {"model": model, "id": mid, "usage": top}}))
' "$@"
}

# run_rows <main-transcript-lines-file> [subagent-lines-file]
# Runs the hook on a main transcript (and optionally one subagent file) and
# prints every row it wrote.
run_rows() {
  local dir fake_home payload
  dir=$(mktemp -d); fake_home=$(mktemp -d)
  cp "$1" "$dir/s.jsonl"
  if [[ -n "${2:-}" ]]; then
    mkdir -p "$dir/s/subagents"
    cp "$2" "$dir/s/subagents/agent-a1.jsonl"
  fi
  payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t324"}))' "$dir/s.jsonl")
  printf '%s' "$payload" | HOME="$fake_home" MH_COST_TRACKER_SETTLE_S=0 bash "$SCRIPT" >/dev/null 2>/dev/null
  cat "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null
  python3 "$ROOT/tests/_lib/tmp_delete.py" "$dir" "$fake_home" || true
}
fx=$(mktemp -d)

# 1. One advisor iteration -> a fable row with exactly that iteration's tokens;
#    the executor's own sonnet row is unchanged (1 turn, its own tokens).
adv_line claude-sonnet-5 msg_adv1 > "$fx/one.jsonl"
rows=$(run_rows "$fx/one.jsonl")
fable=$(jq -c 'select(.model == "claude-fable-5-1")' <<<"$rows")
sonnet=$(jq -c 'select(.model == "claude-sonnet-5")' <<<"$rows")
if [[ "$(jq -r '[.input_tokens, .output_tokens, .turns, .estimated_cost_usd, .stream] | @tsv' <<<"$fable")" == $'1000000\t10000\t0\t10.5\torchestrator' ]]; then
  ok4 "one advisor iteration writes a claude-fable-5-1 row: 1000000 in, 10000 out, 0 turns, \$10.50"
else
  bad4 "advisor row wrong or missing: ${fable:-<none>} (expected fable row 1000000/10000, turns 0, \$10.50)"
fi
if [[ "$(jq -r '[.input_tokens, .output_tokens, .cache_read_tokens, .turns, .cache_read_per_turn] | @tsv' <<<"$sonnet")" == $'1000\t100\t5000\t1\t5000' ]]; then
  ok4 "the executor's own row is unchanged: 1000 in, 100 out, 5000 cache read, 1 turn"
else
  bad4 "executor row changed: $sonnet (expected 1000/100/5000, 1 turn, 5000 per turn)"
fi

# 2. Same model on both sides (a fable executor calling a fable advisor): the
#    rows merge, but turns stays 1 and cache_read_per_turn stays the executor's.
adv_line claude-fable-5-1 msg_adv2 > "$fx/same.jsonl"
row=$(run_rows "$fx/same.jsonl" | jq -c 'select(.model == "claude-fable-5-1")')
if [[ "$(jq -r '[.input_tokens, .output_tokens, .turns, .cache_read_per_turn] | @tsv' <<<"$row")" == $'1001000\t10100\t1\t5000' ]]; then
  ok4 "executor and advisor on one model: tokens add (1001000 in), turns stays 1, cache_read_per_turn 5000"
else
  bad4 "same-model merge wrong: $row (expected 1001000 in, 10100 out, 1 turn, 5000 per turn)"
fi

# 3. One response spans several lines (one per content block), and a copy of
#    the same message.id can land in a subagent file: the advisor counts once.
{ adv_line claude-sonnet-5 msg_adv3; adv_line claude-sonnet-5 msg_adv3; } > "$fx/dup-main.jsonl"
adv_line claude-sonnet-5 msg_adv3 > "$fx/dup-sub.jsonl"
fin=$(run_rows "$fx/dup-main.jsonl" "$fx/dup-sub.jsonl" | jq -s '[.[] | select(.model == "claude-fable-5-1") | .input_tokens] | add')
if [[ "$fin" == "1000000" ]]; then
  ok4 "an advisor call repeated across lines and a subagent copy counts once (1000000 in)"
else
  bad4 "duplicated advisor call counted $fin input tokens, expected 1000000"
fi

# 3b. An advisor call made only inside a subagent is priced on the subagent stream.
make_usage_line 1000 > "$fx/plain.jsonl"
adv_line claude-sonnet-5 msg_adv5 > "$fx/sub-only.jsonl"
row=$(run_rows "$fx/plain.jsonl" "$fx/sub-only.jsonl" | jq -c 'select(.model == "claude-fable-5-1")')
if [[ "$(jq -r '[.stream, .input_tokens, .turns] | @tsv' <<<"$row")" == $'subagent\t1000000\t0' ]]; then
  ok4 "an advisor call inside a subagent writes a subagent-stream fable row (1000000 in, 0 turns)"
else
  bad4 "subagent-only advisor row wrong or missing: ${row:-<none>}"
fi

# 4. A background-session zeroed copy (every top-level counter 0) carries the
#    advisor iteration too; it must add nothing (the original is billed where
#    it really ran).
adv_line claude-sonnet-5 msg_adv4 zeroed > "$fx/zero.jsonl"
rows=$(run_rows "$fx/zero.jsonl")
if [[ -z "$rows" ]]; then
  ok4 "a zeroed duplicate copy writes no advisor row"
else
  bad4 "zeroed duplicate copy wrote rows: $rows"
fi
python3 "$ROOT/tests/_lib/tmp_delete.py" "$fx" || true
echo "$pass4 passed, $fail4 failed (phase 4)"

# Phase 5 -- build_type_map (GH #379). Failure class: per-file data misattributed
# by a batched rewrite. Five subagents, one row each: two plain types, a type
# that starts with "--" (it must reach jq as an option value, never as a
# positional arg), a meta holding only toolUseId (resolved through the parent's
# Agent tool_use), and no meta at all ("unknown"). Two return windows (a1, a3)
# must land on their own file's row, keyed by the id from the file name.
echo "=== typemap: each subagent row carries its own type and its own return windows ==="
source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
pass5=0
fail5=0
tm_dir=$(fresh_tmpdir)
tm_home=$(fresh_tmpdir)
mkdir -p "$tm_dir/s/subagents"
python3 - "$tm_dir" <<'PY'
import json, sys
d = sys.argv[1]
def use(mid, inp, content=None):
    m = {"model": "claude-sonnet-5", "id": mid, "usage": {"input_tokens": inp, "output_tokens": 0,
         "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}
    if content:
        m["content"] = content
    return json.dumps({"type": "assistant", "message": m})
def ret(i):
    return json.dumps({"type": "user", "message": {"role": "user",
                       "content": "<task-notification>\n<task-id>%s</task-id>\n</task-notification>" % i}})
spawn = [{"type": "tool_use", "name": "Agent", "id": "tu1", "input": {"subagent_type": "mh:reviewer"}}]
with open(d + "/s.jsonl", "w") as f:
    f.write("\n".join([use("m0", 1, spawn), ret("a1"), use("m1", 100), ret("a3"), use("m2", 40)]) + "\n")
metas = {"a1": {"agentType": "Explore"}, "a2": {"agentType": "--help"}, "a3": {"toolUseId": "tu1"},
         "a4": None, "a5": {"agentType": "general-purpose"}}
for n, (i, meta) in enumerate(metas.items()):
    with open("%s/s/subagents/agent-%s.jsonl" % (d, i), "w") as f:
        f.write(use("s" + i, 2 ** n) + "\n")
    if meta is not None:
        with open("%s/s/subagents/agent-%s.meta.json" % (d, i), "w") as f:
            json.dump(meta, f)
PY
tm_payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t379"}))' "$tm_dir/s.jsonl")
printf '%s' "$tm_payload" | HOME="$tm_home" MH_COST_TRACKER_SETTLE_S=0 bash "$SCRIPT" >/dev/null 2>/dev/null
got=$(jq -r 'select(.stream == "subagent") | [.agent_type, .input_tokens, .returns, (.verify_tokens | tostring)] | @tsv' \
  "$tm_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null | LC_ALL=C sort)
want=$'--help\t2\t0\tnull\nExplore\t1\t1\t100\ngeneral-purpose\t16\t0\tnull\nmh:reviewer\t4\t1\t40\nunknown\t8\t0\tnull'
if [[ "$got" == "$want" ]]; then
  pass5=$((pass5 + 1)); echo "PASS: 5 subagents -> 5 rows, each with its own type (meta, --help, toolUseId, none) and its own return window"
else
  fail5=$((fail5 + 1)); echo "FAIL: subagent rows (type, in, returns, verify) were:"$'\n'"$got"$'\n'"expected:"$'\n'"$want" >&2
fi
echo "$pass5 passed, $fail5 failed (phase 5)"

# Phase 6 -- one usage-record def and one sentinel row for both streams (GH #379).
# Failure class: two copies of the same logic drift (a past cw1h fix had to edit
# both). The same two-iteration line (1h writes 300 + 400, flat 1000) in the main
# transcript and in a subagent file must give both rows cw 300 / cw1h 700, and a
# line jq cannot read must give each stream the same sentinel shape.
echo "=== shared defs: both streams split cache writes and write sentinels alike ==="
pass6=0
fail6=0
sd_dir=$(fresh_tmpdir)
mkdir -p "$sd_dir/ok/subagents" "$sd_dir/bad/subagents"
python3 - "$sd_dir" <<'PY'
import json, sys
d = sys.argv[1]
u = {"input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 5,
     "cache_creation": {"ephemeral_5m_input_tokens": 700, "ephemeral_1h_input_tokens": 300},
     "iterations": [{"type": "message", "cache_creation": {"ephemeral_1h_input_tokens": 300}},
                    {"type": "message", "cache_creation": {"ephemeral_1h_input_tokens": 400}}]}
def line(mid, usage):
    return json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": mid, "usage": usage}}) + "\n"
for name, usage in (("ok", u), ("bad", "not-an-object")):
    open("%s/%s.jsonl" % (d, name), "w").write(line("m_main", usage))
    open("%s/%s/subagents/agent-a1.jsonl" % (d, name), "w").write(line("m_sub", usage))
    open("%s/%s/subagents/agent-a1.meta.json" % (d, name), "w").write('{"agentType":"Explore"}')
PY
# sd_rows <name>: run the hook on $sd_dir/<name>.jsonl, print its rows without timestamps, stderr to $sd_dir/<name>.err
sd_rows() {
  local home payload
  home=$(fresh_tmpdir)
  payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t379"}))' "$sd_dir/$1.jsonl")
  printf '%s' "$payload" | HOME="$home" MH_COST_TRACKER_SETTLE_S=0 bash "$SCRIPT" >/dev/null 2>"$sd_dir/$1.err"
  jq -c 'del(.timestamp)' "$home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null
}
got=$(sd_rows ok | jq -r '[.stream, .cache_write_tokens, .cache_write_tokens_1h, .input_tokens, .output_tokens, .cache_read_tokens] | @tsv')
if [[ "$got" == $'orchestrator\t300\t700\t10\t20\t5\nsubagent\t300\t700\t10\t20\t5' ]]; then
  pass6=$((pass6 + 1)); echo "PASS: a two-iteration 1h line splits cw 300 / cw1h 700 in both the orchestrator and the subagent row"
else
  fail6=$((fail6 + 1)); echo "FAIL: cache-write split differs by stream or is wrong (stream, cw, cw1h, in, out, cr):"$'\n'"$got" >&2
fi
got=$(sd_rows bad)
want=$(python3 -c '
import json, sys
d = sys.argv[1]
row = lambda s, f: json.dumps({"session_id": "t379", "transcript_path": d + "/bad.jsonl", "stream": s,
                               "error": "jq_failed", "files": f}, separators=(",", ":"))
print(row("orchestrator", d + "/bad.jsonl")); print(row("subagent", d + "/bad/subagents/agent-a1.jsonl"))' "$sd_dir")
if [[ "$got" == "$want" ]] && /usr/bin/grep -q 'emit_rows(subagent): jq failed' "$sd_dir/bad.err" \
   && /usr/bin/grep -q 'emit_rows(orchestrator): jq failed' "$sd_dir/bad.err"; then
  pass6=$((pass6 + 1)); echo "PASS: an unreadable usage line gives each stream the same jq_failed sentinel row, named on stderr"
else
  fail6=$((fail6 + 1)); echo "FAIL: sentinel rows were:"$'\n'"$got"$'\n'"expected:"$'\n'"$want"$'\n'"stderr: $(cat "$sd_dir/bad.err")" >&2
fi
# A subagent usage jq cannot read must not cost the codex tally: the usage and codex
# halves share one jq read, so an error in one must not take the other down.
mkdir -p "$sd_dir/cx/subagents"
python3 - "$sd_dir" <<'PY'
import json, sys
d = sys.argv[1]
def line(mid, usage, tools):
    m = {"model": "claude-opus-5-5", "id": mid, "content": [{"type": "tool_use", "name": n, "input": i} for n, i in tools]}
    if usage is not None:
        m["usage"] = usage
    return json.dumps({"type": "assistant", "message": m}) + "\n"
u = {"input_tokens": 10, "output_tokens": 20}
open(d + "/cx.jsonl", "w").write(line("m_main", u, [("Skill", {"skill": "codex:rescue"})]))
open(d + "/cx/subagents/agent-a1.jsonl", "w").write(
    line("m_bad", "oops", [])
    + line("m_s1", None, [("Agent", {"subagent_type": "codex:codex-rescue"})])
    + line("m_s2", None, [("Skill", {"skill": "codex:review"}), ("Skill", {"skill": "codex:review"})]))
open(d + "/cx/subagents/agent-a1.meta.json", "w").write('{"agentType":"Explore"}')
PY
got=$(sd_rows cx | jq -c 'select(.codex_invocations) | .codex_invocations')
want='{"codex:codex-rescue":1,"codex:rescue":1,"codex:review":2}'
got_sub=$(jq -c 'select(.stream == "subagent") | .error' <<< "$(sd_rows cx)")
if [[ $(jq -cS . <<< "$got") == "$want" && "$got_sub" == '"jq_failed"' ]] \
   && /usr/bin/grep -q 'emit_rows(subagent): jq failed' "$sd_dir/cx.err" \
   && /usr/bin/grep -q 'Cannot index string' "$sd_dir/cx.err"; then
  pass6=$((pass6 + 1)); echo "PASS: a subagent usage jq cannot read keeps the full codex tally and prints jq's own error"
else
  fail6=$((fail6 + 1)); echo "FAIL: codex tally ${got:-<none>} (want $want), subagent error ${got_sub:-<none>}, stderr: $(cat "$sd_dir/cx.err")" >&2
fi
echo "$pass6 passed, $fail6 failed (phase 6)"

# Phase 7 -- argv edge cases (GH #397, #398). Runs under /bin/bash, which is 3.2 on macOS:
# there "${a[@]}" on an empty array is an unbound-variable error under set -u. #397: a session
# with no subagent files must not print that. #398: a subagent file named agent--x.jsonl gives
# the id "-x", which must not reach jq as an option and fail the main-transcript scan.
echo "=== argv edge cases: no subagent files, a subagent id starting with - ==="
pass7=0
fail7=0
ae_dir=$(fresh_tmpdir)
mkdir -p "$ae_dir/dash/subagents"
python3 - "$ae_dir" <<'PY'
import json, sys
d = sys.argv[1]
line = json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "m1",
                   "usage": {"input_tokens": 10, "output_tokens": 20}}}) + "\n"
open(d + "/none.jsonl", "w").write(line)
open(d + "/dash.jsonl", "w").write(line)
open(d + "/dash/subagents/agent--x.jsonl", "w").write(line.replace("m1", "m2"))
PY
# ae_run <name>: run the hook under /bin/bash on $ae_dir/<name>.jsonl, print the orchestrator row, stderr to <name>.err
ae_run() {
  local home payload
  home=$(fresh_tmpdir)
  payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "t397"}))' "$ae_dir/$1.jsonl")
  printf '%s' "$payload" | HOME="$home" MH_COST_TRACKER_SETTLE_S=0 /bin/bash "$SCRIPT" >/dev/null 2>"$ae_dir/$1.err"
  jq -c 'select(.stream == "orchestrator")' "$home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null
}
got=$(ae_run none)
if [[ -s "$ae_dir/none.err" ]]; then
  fail7=$((fail7 + 1)); echo "FAIL: no subagent files printed stderr: $(cat "$ae_dir/none.err")" >&2
elif [[ "$(jq -r .input_tokens <<<"$got" 2>/dev/null)" != "10" ]]; then
  fail7=$((fail7 + 1)); echo "FAIL: no subagent files gave orchestrator row: $got" >&2
else
  pass7=$((pass7 + 1)); echo "PASS: no subagent files: clean stderr and an orchestrator row"
fi
got=$(ae_run dash)
if [[ "$(jq -r '.error // .input_tokens' <<<"$got" 2>/dev/null)" == "10" ]] \
   && ! /usr/bin/grep -q 'Unknown option' "$ae_dir/dash.err"; then
  pass7=$((pass7 + 1)); echo "PASS: subagent id '-x' does not break the main-transcript scan"
else
  fail7=$((fail7 + 1)); echo "FAIL: subagent id '-x' gave orchestrator row: $got"$'\n'"stderr: $(cat "$ae_dir/dash.err")" >&2
fi
echo "$pass7 passed, $fail7 failed (phase 7)"

pass=$((pass + pass2 + pass3 + pass4 + pass5 + pass6 + pass7))
fail=$((fail + fail2 + fail3 + fail4 + fail5 + fail6 + fail7))
echo "TOTAL: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
