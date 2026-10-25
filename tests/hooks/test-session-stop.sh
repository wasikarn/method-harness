#!/usr/bin/env bash
# Stop hook smoke tests: cost-tracker (Stop), memory-audit-commit (Stop).
# These hooks never block
# (no permissionDecision) —
# tests assert exit 0 + expected side effect (stdout injection / env-file
# append / metrics-file append), and that each fails safe (exit 0, no side
# effect) when its required env var is unset.
# Run standalone: bash tests/hooks/test-session-stop.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COST_TRACKER="$ROOT/hooks/stop/cost-tracker.sh"
# No settle wait (GH #329): these fixtures are written before the hook runs.
export MH_COST_TRACKER_SETTLE_S=0
MEMORY_COMMIT="$ROOT/hooks/stop/memory-audit-commit.sh"

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

# make_transcript_line <model> <input_tokens> <output_tokens> [cache_read_tokens]
# One assistant-turn JSONL line. cache_creation is always 0; cache_read defaults to 0
# and is settable because the orchestrator-tax split reports cache_read_per_turn.
make_transcript_line() {
  python3 -c 'import json,sys; print(json.dumps({"type": "assistant", "message": {"model": sys.argv[1],
    "usage": {"input_tokens": int(sys.argv[2]), "output_tokens": int(sys.argv[3]),
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": int(sys.argv[4]) if len(sys.argv) > 4 else 0}}}))' "$1" "$2" "$3" ${4:+"$4"}
}

echo "=== cost-tracker hook (Stop) ==="

fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-session"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
# cost-tracker appends with `jq -c` → one compact JSON object per line (found
# 2026-07-03: the old pretty-printed format broke every line-oriented reader).
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" ]] \
  && /usr/bin/grep -q '"session_id":"test-session"' <<<"$row" \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] \
  && printf '%s' "$row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "echoes payload through + appends one compact JSONL cost row for a valid transcript" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Codex pairing (docs/plans/codex-pairing-2026-09-06.md item F): a Skill call
# to a codex:* skill and an Agent dispatch to a codex:* subagent_type are
# tallied into a separate codex_invocations row -- a count, not a cost. No
# .message.usage on this line, so no usage row is written; the only row
# written is the codex tally, keeping the assertion single-line.
fake_home=$(mktemp -d)
transcript=$(mktemp)
python3 -c '
import json
line = {"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Skill", "input": {"skill": "codex:review", "args": None}},
    {"type": "tool_use", "name": "Agent", "input": {"subagent_type": "codex:codex-rescue"}}
]}}
print(json.dumps(line))
' > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-codex"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" ]] \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] \
  && printf '%s' "$row" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d.get("codex_invocations", {})
sys.exit(0 if c.get("codex:review") == 1 and c.get("codex:codex-rescue") == 1 else 1)
' 2>/dev/null && ok=1 || ok=0
assert "tallies codex:* Skill and Agent tool_use calls into one codex_invocations row" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression: one API response spans several JSONL lines sharing one message.id
# (the usage extraction's 2026-09-04 finding, applies here too) -- 3 duplicate lines
# with the same id, each carrying a codex:review tool_use, must count as ONE
# call, not three.
fake_home=$(mktemp -d)
transcript=$(mktemp)
python3 -c '
import json
line = {"type": "assistant", "message": {"id": "msg_dup1", "content": [
    {"type": "tool_use", "name": "Skill", "input": {"skill": "codex:review", "args": None}}
]}}
for _ in range(3):
    print(json.dumps(line))
' > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-codex-dup"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" ]] \
  && printf '%s' "$row" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("codex_invocations", {}).get("codex:review") == 1 else 1)
' 2>/dev/null && ok=1 || ok=0
assert "3 duplicate JSONL lines sharing one message.id count as 1 codex call, not 3" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

fake_home=$(mktemp -d)
payload=$(python3 -c 'import json; print(json.dumps({"transcript_path": "/nonexistent/transcript.jsonl", "session_id": "test-session"}))')
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && ! -f "$metrics_file" ]] && ok=1 || ok=0
assert "fails safe (exit 0, echoes payload, no metrics row) for a missing transcript" "$ok"
trash "$fake_home" 2>/dev/null || true

# Portability (#93): with jq missing from PATH the tracker must echo the
# payload through and write NOTHING — not garbage rows. Payload is built
# first, with python3/jq still available; NOPY_BIN is a PATH stub dir with
# bash/cat/grep/sed/tr but no jq.
NOPY_BIN=$(mktemp -d "${TMPDIR:-/tmp}/kbg-nojq.XXXXXX")
for _t in bash cat sed tr grep; do
  _src=$(PATH="/usr/bin:/bin" command -v "$_t" || command -v "$_t")
  ln -s "$_src" "$NOPY_BIN/$_t"
done
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-nojq"}))' "$transcript")
out=$(printf '%s' "$payload" | env PATH="$NOPY_BIN" HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && ! -f "$metrics_file" ]] && ok=1 || ok=0
assert "no jq on PATH -> echoes payload, exit 0, zero metrics rows (#93)" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Adversarial: malformed (non-JSON) transcript content. The jq `try fromjson`
# filter skips unparseable lines → usage is null → no row. Must fail safe.
fake_home=$(mktemp -d)
transcript=$(mktemp)
printf 'this is not json\n{ broken\nalso not json\n' > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-session"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && ! -f "$metrics_file" ]] && ok=1 || ok=0
assert "fails safe (exit 0, no metrics row) for a malformed-JSON transcript" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Adversarial: assistant line carries usage: null. The jq
# `select((.message // {}).usage != null)` filter drops it → usage is null → no row.
fake_home=$(mktemp -d)
transcript=$(mktemp)
python3 -c '
import json
line = {"type": "assistant", "message": {"model": "claude-sonnet-5", "usage": None}}
print(json.dumps(line))
' > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test-session"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && ! -f "$metrics_file" ]] && ok=1 || ok=0
assert "fails safe (exit 0, no metrics row) when usage is null" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Adversarial: multi-line transcript (two assistant lines) must aggregate into ONE
# compact JSONL row with summed tokens, not one row per line.
fake_home=$(mktemp -d)
transcript=$(mktemp)
{ make_transcript_line claude-sonnet-5 100 50; make_transcript_line claude-sonnet-5 200 80; } > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "multi"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
# Exactly one row, input_tokens summed to 300 (100+200), output_tokens summed to 130.
[[ "$rc" == "0" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] \
  && /usr/bin/grep -q '"session_id":"multi"' <<<"$row" \
  && /usr/bin/grep -q '"input_tokens":300' <<<"$row" \
  && /usr/bin/grep -q '"output_tokens":130' <<<"$row" \
  && printf '%s' "$row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "aggregates a multi-line transcript into one summed JSONL cost row" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Adversarial (2026-09-04): Claude Code writes one JSONL line per content block of one
# API response, each repeating the same message.id + usage. Three lines with id m1
# (100/50 each) must count once (turns 1, input 100, output 50); a fourth line with id
# m2 (7/3) counts separately → turns 2, input 107, output 53, dedup_usage:true.
fake_home=$(mktemp -d)
transcript=$(mktemp)
dup='{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
{ printf '%s\n' "$dup" "$dup" "$dup"
  printf '%s\n' '{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'; } > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "dedup"}))' "$transcript")
printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" >/dev/null 2>&1
rc=$?
row=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null)
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '"dedup_usage":true' <<<"$row" \
  && /usr/bin/grep -q '"turns":2' <<<"$row" \
  && /usr/bin/grep -q '"input_tokens":107' <<<"$row" \
  && /usr/bin/grep -q '"output_tokens":53' <<<"$row" && ok=1 || ok=0
assert "same message.id repeated on 3 lines counts once (turns 2, input 107, output 53), dedup_usage:true" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Last-line-wins (2026-09-04, measured over 119,013 message ids): the first JSONL line
# of a response carries a streaming placeholder output_tokens, the last the final
# count. Three lines with id m1 (output 2 / 2 / 1500) → output 1500, turns 1,
# usage_pick:"last". (The fixture above repeats identical usage, so it is unchanged.)
fake_home=$(mktemp -d)
transcript=$(mktemp)
for o in 2 2 1500; do
  printf '{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$o"
done > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "lastwins"}))' "$transcript")
printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" >/dev/null 2>&1
rc=$?
row=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null)
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '"usage_pick":"last"' <<<"$row" \
  && /usr/bin/grep -q '"turns":1' <<<"$row" \
  && /usr/bin/grep -q '"input_tokens":100' <<<"$row" \
  && /usr/bin/grep -q '"output_tokens":1500' <<<"$row" && ok=1 || ok=0
assert "same message.id with output 2 / 2 / 1500 across 3 lines → last line wins (output 1500, turns 1), usage_pick:\"last\"" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Adversarial: multi-MODEL transcript (two assistant lines, different `.message.model`)
# must write ONE row PER MODEL, each model_scoped:true, each carrying only that
# model's own tokens — not one summed row tagged with whichever model was last used
# (the pre-fix behavior this rewrite replaced).
fake_home=$(mktemp -d)
transcript=$(mktemp)
{ make_transcript_line claude-opus-4-8 100 50; make_transcript_line claude-sonnet-5 200 80; } > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "multi-model"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
opus_row=$(/usr/bin/grep '"model":"claude-opus-4-8"' "$metrics_file" 2>/dev/null)
sonnet_row=$(/usr/bin/grep '"model":"claude-sonnet-5"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "2" ]] \
  && /usr/bin/grep -q '"model_scoped":true' <<<"$opus_row" \
  && /usr/bin/grep -q '"input_tokens":100' <<<"$opus_row" \
  && /usr/bin/grep -q '"output_tokens":50' <<<"$opus_row" \
  && /usr/bin/grep -q '"model_scoped":true' <<<"$sonnet_row" \
  && /usr/bin/grep -q '"input_tokens":200' <<<"$sonnet_row" \
  && /usr/bin/grep -q '"output_tokens":80' <<<"$sonnet_row" \
  && printf '%s' "$opus_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
  && printf '%s' "$sonnet_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "multi-model transcript writes one model_scoped row per model with that model's own tokens" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Change receipt: every row names the plugin version that wrote it and the HEAD commit of
# the payload's cwd, so a regression is attributable to a policy version and a rollback
# point (harness-engineering checklist, 2026-09-07). Missing plugin root or non-git cwd
# still writes the row with null in those fields.
fake_home=$(mktemp -d)
fake_root=$(mktemp -d)
fake_repo=$(mktemp -d)
transcript=$(mktemp)
mkdir -p "$fake_root/.claude-plugin"
printf '{"name":"mh","version":"9.9.9"}' > "$fake_root/.claude-plugin/plugin.json"
( cd "$fake_repo" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
head_sha=$(git -C "$fake_repo" rev-parse HEAD)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "receipt", "cwd": sys.argv[2]}))' "$transcript" "$fake_repo")
printf '%s' "$payload" | HOME="$fake_home" CLAUDE_PLUGIN_ROOT="$fake_root" bash "$COST_TRACKER" >/dev/null 2>&1
row=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null)
/usr/bin/grep -q '"mh_version":"9.9.9"' <<<"$row" \
  && /usr/bin/grep -q "\"head_commit\":\"$head_sha\"" <<<"$row" && ok=1 || ok=0
assert "row carries mh_version from CLAUDE_PLUGIN_ROOT plugin.json and head_commit of the payload cwd" "$ok"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "receipt-none", "cwd": sys.argv[2]}))' "$transcript" "$fake_home")
printf '%s' "$payload" | HOME="$fake_home" CLAUDE_PLUGIN_ROOT='' bash "$COST_TRACKER" >/dev/null 2>&1
row=$(tail -1 "$fake_home/.local/share/kbg/metrics/costs.jsonl" 2>/dev/null)
/usr/bin/grep -q '"session_id":"receipt-none"' <<<"$row" \
  && /usr/bin/grep -q '"mh_version":null' <<<"$row" \
  && /usr/bin/grep -q '"head_commit":null' <<<"$row" && ok=1 || ok=0
assert "no plugin root and non-git cwd → row still written with mh_version:null, head_commit:null" "$ok"
trash "$fake_home" "$fake_root" "$fake_repo" "$transcript" 2>/dev/null || true

# Orchestrator-tax split. Claude Code writes the main session to
# <project>/<session-id>.jsonl and each subagent to its own file under the sibling
# <project>/<session-id>/subagents/agent-*.jsonl. cost-tracker read only the main
# file, so every subagent's spend was invisible to /cost-report (verified against a
# real 15-subagent session, 2026-08-07: 0 rows with isSidechain:true ever land in the
# main transcript). Assert both halves are now counted, tagged by `stream`, and that
# each row carries the turn count + cache_read-per-turn that make the orchestrator's
# carried-context cost readable — docs/research/orchestrator-tax-gap-analysis-2026-08-07.md.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/sess.jsonl"
mkdir -p "$sess_dir/sess/subagents"
# main: 2 turns, cache_read 1000 each → cache_read_per_turn 1000
{ make_transcript_line claude-sonnet-5 100 50 1000; make_transcript_line claude-sonnet-5 100 50 1000; } > "$transcript"
# subagents: 2 files × 1 turn each, same model → one aggregated subagent row, 2 turns
make_transcript_line claude-sonnet-5 7 3 40 > "$sess_dir/sess/subagents/agent-aaa.jsonl"
make_transcript_line claude-sonnet-5 7 3 40 > "$sess_dir/sess/subagents/agent-bbb.jsonl"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "tax"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
orch_row=$(/usr/bin/grep '"stream":"orchestrator"' "$metrics_file" 2>/dev/null)
sub_row=$(/usr/bin/grep '"stream":"subagent"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "2" ]] \
  && /usr/bin/grep -q '"input_tokens":200' <<<"$orch_row" \
  && /usr/bin/grep -q '"cache_read_tokens":2000' <<<"$orch_row" \
  && /usr/bin/grep -q '"turns":2' <<<"$orch_row" \
  && /usr/bin/grep -q '"cache_read_per_turn":1000' <<<"$orch_row" \
  && /usr/bin/grep -q '"input_tokens":14' <<<"$sub_row" \
  && /usr/bin/grep -q '"cache_read_tokens":80' <<<"$sub_row" \
  && /usr/bin/grep -q '"turns":2' <<<"$sub_row" \
  && printf '%s' "$orch_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
  && printf '%s' "$sub_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "counts subagent transcripts and tags each row with stream + turns + cache_read_per_turn" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# Fails safe when there is no subagents/ dir at all (the common single-agent session):
# one orchestrator row, no empty subagent row, no crash from the empty glob.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/solo.jsonl"
make_transcript_line claude-sonnet-5 100 50 1000 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "solo"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] \
  && /usr/bin/grep -q '"stream":"orchestrator"' "$metrics_file" \
  && ! /usr/bin/grep -q '"stream":"subagent"' "$metrics_file" && ok=1 || ok=0
assert "no subagents/ dir → one orchestrator row, no empty subagent row" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# Per-agent-type breakdown. Claude Code writes an agent-<id>.meta.json sibling next to
# every agent-<id>.jsonl carrying the real `agentType` (the Agent tool's subagent_type
# param) — confirmed shape against a real transcript, 2026-08-07. Two subagent files on
# the SAME model but DIFFERENT agentType must produce two rows, not collapse into one:
# a mh:code-reviewer dispatch and an Explore dispatch on the same model are different
# populations of work, exactly the reasoning behind the earlier stream split.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/types.jsonl"
mkdir -p "$sess_dir/types/subagents"
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/types/subagents/agent-aaa.jsonl"
printf '{"agentType":"mh:code-reviewer","description":"x","toolUseId":"t1","spawnDepth":1}' > "$sess_dir/types/subagents/agent-aaa.meta.json"
make_transcript_line claude-sonnet-5 20 8 > "$sess_dir/types/subagents/agent-bbb.jsonl"
printf '{"agentType":"Explore","description":"y","toolUseId":"t2","spawnDepth":1}' > "$sess_dir/types/subagents/agent-bbb.meta.json"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "types"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
reviewer_row=$(/usr/bin/grep '"agent_type":"mh:code-reviewer"' "$metrics_file" 2>/dev/null)
explore_row=$(/usr/bin/grep '"agent_type":"Explore"' "$metrics_file" 2>/dev/null)
orch_row=$(/usr/bin/grep '"stream":"orchestrator"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "3" ]] \
  && /usr/bin/grep -q '"input_tokens":10' <<<"$reviewer_row" \
  && /usr/bin/grep -q '"input_tokens":20' <<<"$explore_row" \
  && /usr/bin/grep -q '"agent_type":null' <<<"$orch_row" \
  && printf '%s' "$reviewer_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
  && printf '%s' "$explore_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "subagent rows split by agent_type (from meta.json sibling) even on the same model; orchestrator row carries agent_type:null" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# Missing meta.json sibling (older sessions, or a subagent that never got one) must
# fail safe to agent_type:"unknown" — never drop the row, never crash.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/nometa.jsonl"
mkdir -p "$sess_dir/nometa/subagents"
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/nometa/subagents/agent-ccc.jsonl"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "nometa"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
sub_row=$(/usr/bin/grep '"stream":"subagent"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && -f "$metrics_file" ]] \
  && /usr/bin/grep -q '"agent_type":"unknown"' <<<"$sub_row" \
  && printf '%s' "$sub_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "subagent transcript with no .meta.json sibling falls back to agent_type:\"unknown\" (fails safe, no crash)" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# meta.json present but agentType empty/missing → fall back to the parent transcript's
# Agent tool_use `.input.subagent_type`, joined on meta's toolUseId (the one other place
# the type is recorded; verified 2026-09-03 the subagent JSONL carries none). A toolUseId
# with no matching parent tool_use still lands on "unknown", never a crash.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/fb.jsonl"
mkdir -p "$sess_dir/fb/subagents"
{
  make_transcript_line claude-sonnet-5 100 50
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_fb1","name":"Agent","input":{"subagent_type":"mh:plan-reviewer","prompt":"x"}}]}}\n'
} > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/fb/subagents/agent-ddd.jsonl"
printf '{"description":"no type","toolUseId":"toolu_fb1","spawnDepth":1}' > "$sess_dir/fb/subagents/agent-ddd.meta.json"
make_transcript_line claude-sonnet-5 20 8 > "$sess_dir/fb/subagents/agent-eee.jsonl"
printf '{"agentType":"","toolUseId":"toolu_nomatch","spawnDepth":1}' > "$sess_dir/fb/subagents/agent-eee.meta.json"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "fb"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
fb_row=$(/usr/bin/grep '"agent_type":"mh:plan-reviewer"' "$metrics_file" 2>/dev/null)
unk_row=$(/usr/bin/grep '"agent_type":"unknown"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && -f "$metrics_file" ]] \
  && /usr/bin/grep -q '"input_tokens":10' <<<"$fb_row" \
  && /usr/bin/grep -q '"input_tokens":20' <<<"$unk_row" \
  && printf '%s' "$fb_row" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && ok=1 || ok=0
assert "meta.json without agentType falls back to parent transcript's Agent tool_use subagent_type via toolUseId; unmatched toolUseId stays \"unknown\"" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# Claude-only tracking (2026-08-07, operator request): a session can run non-Claude
# models (e.g. via a proxy that swaps ANTHROPIC_BASE_URL — confirmed real in
# production data: minimax-m3, glm-5.2, kimi-k2.7-code, nemotron-3-super all showed
# real spend). The tracker must write a row ONLY for turns whose `.message.model`
# matches claude-*, and silently drop non-Claude turns — not error, not fold them
# into an "unknown" row, not let them inflate any Claude row's totals.
fake_home=$(mktemp -d)
transcript=$(mktemp)
{ make_transcript_line claude-sonnet-5 100 50; make_transcript_line minimax-m3 999 999; } > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "mixed-vendor"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" \
  && "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] \
  && /usr/bin/grep -q '"model":"claude-sonnet-5"' "$metrics_file" \
  && /usr/bin/grep -q '"input_tokens":100' "$metrics_file" \
  && ! /usr/bin/grep -qi 'minimax' "$metrics_file" && ok=1 || ok=0
assert "non-Claude model turns (minimax-m3) are silently dropped — only the claude-sonnet-5 row is written, with its own tokens, not inflated by the dropped turn" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# A transcript with ONLY non-Claude turns must write no row at all (not a crash, not
# an empty/garbage row) — the existing "no usage → no row" fail-safe path.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line glm-5.2 50 20 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "all-foreign"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc" == "0" && "$out" == "$payload" && ! -f "$metrics_file" ]] && ok=1 || ok=0
assert "an all-non-Claude transcript (glm-5.2 only) writes no metrics row at all" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression (H7): a real jq failure (a transcript line whose .message.usage is
# a non-object, which the pipeline's own `try fromjson` can't catch since the
# error is in the *selector*, not the parse) must not silently look like the
# legitimate "no Claude usage this session" case. Before the fix, `usages=''`
# either way and NO row was written at all -- indistinguishable from a clean
# empty session. After the fix, a sentinel row with error:"jq_failed" is
# written and a diagnostic is printed to stderr.
#
# 2026-09-22 deep-audit finding: scan_transcript's usages sub-expression used
# to swallow the actual jq error text via a bare `catch {__error: true}` --
# the sentinel row was still correct, but the specific error (e.g. "Cannot
# index string with...") never reached stderr, only a generic log line. Fixed
# by carrying `msg: .` through the catch; asserted here via the exact error
# fragment jq produces for this fixture, not just the generic "jq failed"
# substring (which passed both before and after that fix).
fake_home=$(mktemp -d)
transcript=$(mktemp)
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":"not-an-object","id":"m1"}}' > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "jq-fail-test"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/tmp/mh-test-jqfail-stderr.$$)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && "$out" == "$payload" && -f "$metrics_file" ]] \
  && /usr/bin/grep -q "jq failed" /tmp/mh-test-jqfail-stderr.$$ \
  && /usr/bin/grep -q 'Cannot index string with string' /tmp/mh-test-jqfail-stderr.$$ \
  && printf '%s' "$row" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("error") == "jq_failed" and d.get("stream") == "orchestrator" else 1)
' 2>/dev/null && ok=1 || ok=0
assert "a real jq failure (non-object .message.usage) emits a jq_failed sentinel row + the actual jq error text on stderr (not just a generic log line)" "$ok"
trash "$fake_home" "$transcript" "/tmp/mh-test-jqfail-stderr.$$" 2>/dev/null || true

# H8 (harness gap-audit, 2026-09-20): end-to-end proof that a real transcript
# run through cost-tracker.sh itself actually populates verify_tokens/
# verify_cache_read/verify_per_return in costs.jsonl -- restored/adapted from
# commit 6603c384 (removed by 2cac98c8), which every other cost-report test
# only exercises via pre-fabricated fixture rows, never this emission path.
# Main transcript: dispatch (Agent tool_use) -> its return as a
# <task-notification> user line -> two assistant turns (100+0+50, 200+0+80 =
# 430 verify tokens, 7+3 cache_read) -> next Agent tool_use (counted, closes
# the window) -> a turn after it (NOT counted).
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/verify.jsonl"
mkdir -p "$sess_dir/verify/subagents"
agent_dispatch='{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","name":"Agent","id":"t1","input":{"subagent_type":"general-purpose"}}],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
{ printf '%s\n' "$agent_dispatch"
  python3 -c 'import json; print(json.dumps({"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>aaa</task-id>\n<status>completed</status>\n</task-notification>"}}))'
  make_transcript_line claude-sonnet-5 100 50 7
  # (2026-09-21) a background-Bash completion uses the same <task-notification>
  # tag with a task-id that matches no agent-<id>.jsonl. It must neither open a
  # second window (returns 2) nor close the real one early (verify_tokens 100).
  python3 -c 'import json; print(json.dumps({"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>bash-0042</task-id>\n<status>completed</status>\n</task-notification>"}}))'
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","name":"Agent","id":"t2","input":{"subagent_type":"general-purpose"}}],"usage":{"input_tokens":200,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":3}}}'
  make_transcript_line claude-sonnet-5 999 999; } > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/verify/subagents/agent-aaa.jsonl"
printf '{"agentType":"general-purpose","toolUseId":"t1","spawnDepth":1}' > "$sess_dir/verify/subagents/agent-aaa.meta.json"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "verify"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
sub_row=$(/usr/bin/grep '"stream":"subagent"' "$metrics_file" 2>/dev/null)
orch_row=$(/usr/bin/grep '"stream":"orchestrator"' "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" ]] \
  && /usr/bin/grep -q '"returns":1,"verify_tokens":430,"verify_cache_read":10,"verify_per_return":\[430\]' <<<"$sub_row" \
  && /usr/bin/grep -q '"returns":1,"verify_tokens":430' <<<"$orch_row" && ok=1 || ok=0
assert "H8: task-notification -> next Agent tool_use window summed into verify_tokens (430, cache_read 10) via a real cost-tracker.sh run, not a fabricated row; turn after the dispatch excluded; a background-command notification (no agent-<id>.jsonl) neither adds a return nor closes the window" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# H8 negative case: a transcript with no <task-notification> at all must still
# write a row, with verify_tokens/verify_cache_read null and returns:0 -- not
# a crash, not a stale/leftover value from a previous run.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "no-notification"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" ]] && /usr/bin/grep -q '"returns":0,"verify_tokens":null,"verify_cache_read":null,"verify_per_return":\[\]' <<<"$row" && ok=1 || ok=0
assert "H8: a transcript with no task-notification writes returns:0, verify_tokens:null via a real cost-tracker.sh run" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression risk specific to the 2026-09-22 single-scan refactor: H7's
# usage:"not-an-object" line now sits INSIDE an open verify-window (after a
# real agent dispatch + its <task-notification>, before the closing Agent
# tool_use) instead of alone in an otherwise-empty transcript. Before
# scan_transcript's verify_map/parent_map/codex sub-expressions were
# individually try/caught, this exact shape threw inside the *combined*
# single-pass jq call and was silently swallowed: no jq_failed sentinel row,
# no orchestrator row at all -- exactly the "no row" H7 exists to distinguish
# from "no spend that turn." Fixed against this file at HEAD; would fail red
# against the version between the single-scan consolidation and this fix.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/winfail.jsonl"
mkdir -p "$sess_dir/winfail/subagents"
agent_dispatch='{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","name":"Agent","id":"t1","input":{"subagent_type":"general-purpose"}}],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
{ printf '%s\n' "$agent_dispatch"
  python3 -c 'import json; print(json.dumps({"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>aaa</task-id>\n<status>completed</status>\n</task-notification>"}}))'
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":"not-an-object","id":"m1"}}'; } > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/winfail/subagents/agent-aaa.jsonl"
printf '{"agentType":"general-purpose","toolUseId":"t1","spawnDepth":1}' > "$sess_dir/winfail/subagents/agent-aaa.meta.json"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "winfail"}))' "$transcript")
err=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>&1 >/dev/null)
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
orch_row=$(/usr/bin/grep '"stream":"orchestrator"' "$metrics_file" 2>/dev/null)
sub_row=$(/usr/bin/grep '"stream":"subagent"' "$metrics_file" 2>/dev/null)
[[ -f "$metrics_file" ]] \
  && /usr/bin/grep -q "jq failed" <<<"$err" \
  && /usr/bin/grep -q '"error":"jq_failed"' <<<"$orch_row" \
  && /usr/bin/grep -q '"agent_type":"general-purpose"' <<<"$sub_row" && ok=1 || ok=0
assert "a usage-type-error line inside an OPEN verify window still emits the orchestrator jq_failed sentinel (not silence), and the subagent row still writes correctly" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

# Regression (M8): unset/relative HOME must never resolve metrics writes into
# the current working directory (this exact bug once wrote a metrics file
# into this repo's own tree, 2026-08-28). Skip metrics entirely, still echo
# the payload through cleanly.
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "home-unset-test"}))' "$transcript")
before_count=$(find "$ROOT" -name costs.jsonl 2>/dev/null | wc -l | tr -d ' ')
out=$(printf '%s' "$payload" | env -u HOME bash "$COST_TRACKER" 2>/dev/null)
rc=$?
after_count=$(find "$ROOT" -name costs.jsonl 2>/dev/null | wc -l | tr -d ' ')
[[ "$rc" == "0" && "$out" == "$payload" && "$before_count" == "$after_count" ]] && ok=1 || ok=0
assert "unset HOME skips metrics entirely instead of writing into the repo tree" "$ok"
trash "$transcript" 2>/dev/null || true

# GH #117: cost-tracker is stateless by design, re-deriving cumulative totals
# from the full transcript on every Stop -- so if the same Stop event ever
# fires twice for one turn (transcript unchanged in between), the append had
# no completion marker to recognize that and would double-write the row. The
# summarized mh:cost-report is unaffected (it keeps the latest row per session
# and model key, see skills/meta/cost-report/references/data-model.md); raw-row consumers such
# as the CSV mode see the duplicate. Same session_id + same transcript path +
# same transcript byte size = the identical prior state, not a new turn.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "dup-stop"}))' "$transcript")
out1=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc1=$?
out2=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc2=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc1" == "0" && "$rc2" == "0" && "$out1" == "$payload" && "$out2" == "$payload" ]] \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] && ok=1 || ok=0
assert "GH #117: the same Stop event firing twice for an unchanged transcript writes the cost row only once" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Control: a real second turn (transcript grew) must NOT be swallowed by the
# dedup marker -- only an exact repeat of the prior state is skipped.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "grown-stop"}))' "$transcript")
out1=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc1=$?
make_transcript_line claude-sonnet-5 200 80 >> "$transcript"
out2=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc2=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
[[ "$rc1" == "0" && "$rc2" == "0" ]] \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "2" ]] && ok=1 || ok=0
assert "a real second turn (transcript grew) after the first Stop still writes its own row" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression: the completion marker must not be set when the symlink guard
# blocked a real (non-empty) append -- a lease set on a write that never
# happened would let a later retry (transcript unchanged) skip forever
# without ever persisting the row. Plant costs.jsonl as a symlink so the
# guard fires, then remove it and retry: the retry must still write the row.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "symlink-blocked"}))' "$transcript")
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir"
decoy=$(mktemp)
ln -s "$decoy" "$metrics_dir/costs.jsonl"
out1=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc1=$?
trash "$metrics_dir/costs.jsonl" 2>/dev/null || rm -f "$metrics_dir/costs.jsonl"
out2=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc2=$?
metrics_file="$metrics_dir/costs.jsonl"
[[ "$rc1" == "0" && "$rc2" == "0" && "$out1" == "$payload" && "$out2" == "$payload" ]] \
  && [[ -f "$metrics_file" && ! -L "$metrics_file" ]] \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] && ok=1 || ok=0
assert "a symlink-blocked append doesn't set the completion marker, so a retry still persists the row" "$ok"
trash "$fake_home" "$transcript" "$decoy" 2>/dev/null || true

# Regression (deep-audit finding, MEDIUM): the symlink guard is only ONE way
# the append can fail to persist a real row -- any other append failure must
# also not set the marker. Structural failure, uid-independent (a chmod-based
# fixture is a no-op as root -- same ENOTDIR-style precedent as
# tests/hooks/test-gate-journal.sh's case 3): plant costs.jsonl as a
# DIRECTORY, so `>> costs.jsonl` fails with "Is a directory" without ever
# tripping the `-L` (symlink) check.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "append-failed"}))' "$transcript")
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir/costs.jsonl"
out1=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc1=$?
rmdir "$metrics_dir/costs.jsonl" 2>/dev/null
out2=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc2=$?
metrics_file="$metrics_dir/costs.jsonl"
[[ "$rc1" == "0" && "$rc2" == "0" && "$out1" == "$payload" && "$out2" == "$payload" ]] \
  && [[ -f "$metrics_file" ]] \
  && [[ "$(wc -l < "$metrics_file" | tr -d ' ')" == "1" ]] && ok=1 || ok=0
assert "a non-symlink append failure (Is a directory) doesn't set the completion marker either, so a retry still persists the row" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression (deep-audit finding, path traversal): session_id is taken
# verbatim from the Stop payload and interpolated into a filesystem path
# (marker_dir/$session_id) with no validation, unlike scripts/_lib/
# hook_payload.py's shared session_id validator used elsewhere in this repo.
# A session_id containing ".." must not let the marker write escape
# .markers/ -- confirm no file appears at the traversal target and the
# marker instead lands at the safe fallback.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "../../evil-mh-test-marker"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_dir="$fake_home/.local/share/kbg/metrics"
escape_target="$fake_home/.local/share/evil-mh-test-marker"
[[ "$rc" == "0" && "$out" == "$payload" ]] \
  && [[ ! -e "$escape_target" ]] \
  && [[ -f "$metrics_dir/.markers/default" ]] && ok=1 || ok=0
assert "a session_id containing .. doesn't let the completion marker write escape .markers/" "$ok"
trash "$fake_home" "$transcript" 2>/dev/null || true

# Regression (deep-audit finding, 2026-09-21): the marker write is `>` into
# .markers/<session_id>; a pre-planted symlink there would be followed and the
# target truncated + overwritten with the dedup key -- the same threat the
# costs.jsonl append already guards with `-L`. The row must still be appended
# (the guard skips only the marker write) and the decoy must be untouched.
fake_home=$(mktemp -d)
transcript=$(mktemp)
make_transcript_line claude-sonnet-5 100 50 > "$transcript"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "marker-symlink"}))' "$transcript")
metrics_dir="$fake_home/.local/share/kbg/metrics"
mkdir -p "$metrics_dir/.markers"
decoy=$(mktemp)
printf 'decoy-untouched\n' > "$decoy"
ln -s "$decoy" "$metrics_dir/.markers/marker-symlink"
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
[[ "$rc" == "0" && "$out" == "$payload" ]] \
  && [[ "$(cat "$decoy")" == "decoy-untouched" ]] \
  && [[ "$(wc -l < "$metrics_dir/costs.jsonl" | tr -d ' ')" == "1" ]] && ok=1 || ok=0
assert "a symlinked .markers/<session_id> is not followed: decoy untouched, row still appended" "$ok"
trash "$fake_home" "$transcript" "$decoy" 2>/dev/null || true

# --- 2026-09-22 single-scan perf fix (TDD refactor loop) ---
# Before the fix, cost-tracker.sh re-scanned the main transcript with a
# separate full-file jq invocation 3-5 times per Stop call (build_verify_map
# for the orchestrator typemap, emit_rows' own orchestrator extraction,
# emit_codex_invocations, and -- when subagents exist -- build_type_map's own
# parent_map extraction PLUS its own internal build_verify_map re-scan of the
# identical input). Measured 9.5s/Stop-call against a real 158MB/42,838-line
# transcript on disk. This wraps jq with a shim that logs every invocation's
# arguments, distinguishing a real file-read (transcript path as a positional
# operand) from the path merely being embedded as a --arg/--argjson STRING
# VALUE (used only to label output rows, never causes a file read).
real_jq=$(command -v jq)
jq_shim_dir=$(mktemp -d)
jq_log=$(mktemp)
cat > "$jq_shim_dir/jq" <<EOF
#!/usr/bin/env bash
real_jq="$real_jq"
jq_log="$jq_log"
EOF
cat >> "$jq_shim_dir/jq" <<'INNER'
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  if [[ "$a" == "--arg" || "$a" == "--argjson" ]]; then
    i=$((i+3))
    continue
  fi
  if [[ "$a" == "$TRANSCRIPT_UNDER_TEST" ]]; then
    echo "hit" >> "$jq_log"
  elif [[ -n "${SUB_UNDER_TEST:-}" && "$a" == "$SUB_UNDER_TEST" ]]; then
    echo "sub" >> "$jq_log"
  fi
  i=$((i+1))
done
exec "$real_jq" "$@"
INNER
chmod +x "$jq_shim_dir/jq"

fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/passcount.jsonl"
mkdir -p "$sess_dir/passcount/subagents"
{ make_transcript_line claude-sonnet-5 100 50
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","name":"Agent","id":"t1","input":{"subagent_type":"general-purpose"}}],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
  make_transcript_line claude-sonnet-5 50 20; } > "$transcript"
make_transcript_line claude-sonnet-5 10 5 > "$sess_dir/passcount/subagents/agent-aaa.jsonl"
printf '{"agentType":"general-purpose","toolUseId":"t1","spawnDepth":1}' > "$sess_dir/passcount/subagents/agent-aaa.meta.json"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "passcount"}))' "$transcript")
printf '%s' "$payload" | TRANSCRIPT_UNDER_TEST="$transcript" SUB_UNDER_TEST="$sess_dir/passcount/subagents/agent-aaa.jsonl" PATH="$jq_shim_dir:$PATH" HOME="$fake_home" bash "$COST_TRACKER" >/dev/null 2>&1
rc=$?
hits=$(/usr/bin/grep -c '^hit$' "$jq_log")
sub_hits=$(/usr/bin/grep -c '^sub$' "$jq_log")
[[ "$rc" == "0" && "$hits" == "1" ]] && ok=1 || ok=0
assert "cost-tracker.sh scans the main transcript with jq exactly once per Stop call (was 3-5x before the single-pass consolidation)" "$ok"
# 2026-10-22 lane-3 fold: usage rows and codex tallies come from one jq read of each subagent file (was 2).
[[ "$rc" == "0" && "$sub_hits" == "1" ]] && ok=1 || ok=0
assert "cost-tracker.sh reads each subagent transcript with jq exactly once per Stop call (got $sub_hits)" "$ok"
trash "$fake_home" "$sess_dir" "$jq_shim_dir" "$jq_log" 2>/dev/null || true

# Regression risk specific to the single-scan refactor: codex tool_use tallies
# from the main transcript and from a subagent file must be SUMMED per key,
# not have one overwrite the other. The original code tallied every file's
# lines together in one combined jq call; the refactor computes the main
# transcript's contribution separately (via scan_transcript) and merges it
# additively with the subagent files' contribution (from the subagent jq read)
# -- an overwrite-instead-of-add merge bug would silently undercount.
fake_home=$(mktemp -d)
sess_dir=$(mktemp -d)
transcript="$sess_dir/codexmerge.jsonl"
mkdir -p "$sess_dir/codexmerge/subagents"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"codex:review","args":null}}]}}\n' > "$transcript"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"codex:review","args":null}}]}}\n' > "$sess_dir/codexmerge/subagents/agent-zzz.jsonl"
payload=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": "codexmerge"}))' "$transcript")
out=$(printf '%s' "$payload" | HOME="$fake_home" bash "$COST_TRACKER" 2>/dev/null)
rc=$?
metrics_file="$fake_home/.local/share/kbg/metrics/costs.jsonl"
row=$(tail -1 "$metrics_file" 2>/dev/null)
[[ "$rc" == "0" && -f "$metrics_file" ]] \
  && printf '%s' "$row" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("codex_invocations", {}).get("codex:review") == 2 else 1)
' 2>/dev/null && ok=1 || ok=0
assert "codex:review called once in the main transcript and once in a subagent file sums to 2, not 1 (additive merge, not overwrite)" "$ok"
trash "$fake_home" "$sess_dir" 2>/dev/null || true

echo ""
echo "=== memory-audit-commit hook (Stop) ==="

fake_home=$(mktemp -d)

# Each case gets its own project dir → own encoded memory dir, so no
# leftover state (untracked files, prior commits) from one case can leak
# into the next.
proj_noopt=$(mktemp -d)
mem_noopt="$fake_home/.claude/projects/$(cd "$proj_noopt" && pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')/memory"
mkdir -p "$mem_noopt"
echo "not opted in" > "$mem_noopt/f.md"
out=$(cd "$proj_noopt" && HOME="$fake_home" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$MEMORY_COMMIT" 2>/dev/null)
rc=$?
still_no_git="no"; [[ "$(cd "$mem_noopt" && git rev-parse --is-inside-work-tree 2>&1)" != "true" ]] && still_no_git="yes"
[[ "$rc" == "0" && -z "$out" && "$still_no_git" == "yes" ]] && ok=1 || ok=0
assert "no-op (exit 0, no repo created) when the memory dir isn't already a git repo" "$ok"

proj=$(mktemp -d)
mem_dir="$fake_home/.claude/projects/$(cd "$proj" && pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')/memory"
mkdir -p "$mem_dir"
echo "# Memory index" > "$mem_dir/MEMORY.md"
(cd "$mem_dir" && git init -q && git config user.email test@test && git config user.name test && git add MEMORY.md && git -c user.email=test@test -c user.name=test commit -q -m baseline)
# ^ local (non --global) identity persisted on the fixture repo, not just the baseline commit:
# memory-audit-commit.sh:48 commits with no -c flags of its own, inheriting whatever identity
# is already configured for $mem_dir -- a bare CI container has no ambient global git identity
# (confirmed live on Ubuntu 24.04), so without this the hook's own auto-commit silently fails
# (stderr redirected to /dev/null, exit 0 regardless) and the two assertions below see a dirty
# working tree instead of a clean one.

before=$(cd "$mem_dir" && git rev-parse HEAD)
out=$(cd "$proj" && HOME="$fake_home" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$MEMORY_COMMIT" 2>/dev/null)
rc=$?
after=$(cd "$mem_dir" && git rev-parse HEAD)
[[ "$rc" == "0" && "$before" == "$after" ]] && ok=1 || ok=0
assert "clean tree → no-op, HEAD unchanged" "$ok"

echo "new memory" > "$mem_dir/new-note.md"
out=$(cd "$proj" && HOME="$fake_home" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$MEMORY_COMMIT" 2>/dev/null)
rc=$?
log_count=$(cd "$mem_dir" && git log --oneline | wc -l | tr -d ' ')
porcelain=$(cd "$mem_dir" && git status --porcelain)
[[ "$rc" == "0" && "$log_count" == "2" && -z "$porcelain" ]] && ok=1 || ok=0
assert "new untracked file → auto-committed, working tree clean after" "$ok"

echo "edited" >> "$mem_dir/MEMORY.md"
out=$(cd "$proj" && HOME="$fake_home" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$MEMORY_COMMIT" 2>/dev/null)
rc=$?
log_count2=$(cd "$mem_dir" && git log --oneline | wc -l | tr -d ' ')
porcelain2=$(cd "$mem_dir" && git status --porcelain)
[[ "$rc" == "0" && "$log_count2" == "3" && -z "$porcelain2" ]] && ok=1 || ok=0
assert "edit to an already-tracked file → auto-committed, working tree clean after" "$ok"

trash "$fake_home" "$proj_noopt" "$proj" 2>/dev/null || true

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
