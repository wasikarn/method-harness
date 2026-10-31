#!/usr/bin/env bash
# test-model-bench.sh — exercises skills/meta/model-bench/scripts/model-bench-diff.py's
# --diff-only report against static fixtures built to the real aggregate-result.json schema
# (verified against every file under evals/results/ on this machine, not guessed — see the
# plan history in skills/meta/model-bench/SKILL.md). Fixtures are hand-authored rather than
# derived from a live evals/results/ dir at test time: that directory is gitignored, so a
# fresh clone or CI runner has none to derive from.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$ROOT/scripts/_lib/tmp-delete.sh"
DIFF_PY="$ROOT/skills/meta/model-bench/scripts/model-bench-diff.py"
FIXTURES="$HERE/fixtures/model-bench"
TMP_MODELS="$(mktemp)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== model-bench-diff.py self-test ==="

# --- clean pair: happy path, per-case table, outer-join, agent-dispatch caveat ---
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/clean-b.json" 2>&1)
status=$?

if [ "$status" -eq 0 ]; then ok "clean pair: exit 0"; else bad "clean pair: exit $status (expected 0)"; fi

/usr/bin/grep -qF 'shared-skill-case' <<<"$out" \
  && /usr/bin/grep -qF '+0.050' <<<"$out" \
  && ok "clean pair: shared-skill-case delta is +0.050 (0.95 - 0.9)" \
  || bad "clean pair: shared-skill-case delta wrong or missing"

/usr/bin/grep -qF 'shared-agent-case' <<<"$out" \
  && /usr/bin/grep -qF '+0.200' <<<"$out" \
  && ok "clean pair: shared-agent-case delta is +0.200 (0.8 - 0.6)" \
  || bad "clean pair: shared-agent-case delta wrong or missing"

/usr/bin/grep -qF 'only-in-a: only in fixture-a' <<<"$out" \
  && /usr/bin/grep -qF 'only-in-b: only in fixture-b' <<<"$out" \
  && ok "clean pair: outer-join lists both one-sided cases under their real label" \
  || bad "clean pair: outer-join missing a one-sided case"

/usr/bin/grep -qF 'CAVEAT: 1 of 2 compared cases dispatch a subagent' <<<"$out" \
  && ok "clean pair: agent-dispatch caveat counts exactly the 1 case with subagent_type" \
  || bad "clean pair: agent-dispatch caveat count wrong or missing"

/usr/bin/grep -q 'WARN' <<<"$out" \
  && bad "clean pair: printed a WARN with nothing that should mismatch" \
  || ok "clean pair: no spurious WARN"

/usr/bin/grep -qF 'safety classifiers' <<<"$out" \
  && bad "clean pair: content-fallback caveat printed for non-model labels" \
  || ok "clean pair: no content-fallback caveat for non-model labels"

# --- content-fallback caveat: fires only for an arm on a classifier-backed model ---
out=$(python3 "$DIFF_PY" --label-a sonnet@high --label-b claude-opus-5-5 \
  "$FIXTURES/clean-a.json" "$FIXTURES/clean-b.json" 2>&1)
/usr/bin/grep -qF 'CAVEAT: claude-opus-5-5 runs a model with safety classifiers' <<<"$out" \
  && ok "opus-5-5 arm: content-fallback caveat names the arm" \
  || bad "opus-5-5 arm: content-fallback caveat missing"

# `default` resolves to Opus 5.5 on every plan (model-config#default-model-setting)
out=$(python3 "$DIFF_PY" --label-a default --label-b sonnet \
  "$FIXTURES/clean-a.json" "$FIXTURES/clean-b.json" 2>&1)
/usr/bin/grep -qF 'CAVEAT: default runs a model with safety classifiers' <<<"$out" \
  && ok "default arm: content-fallback caveat names the arm" \
  || bad "default arm: content-fallback caveat missing"

out=$(python3 "$DIFF_PY" --label-a claude-opus-4-8 --label-b sonnet \
  "$FIXTURES/clean-a.json" "$FIXTURES/clean-b.json" 2>&1)
/usr/bin/grep -qF 'safety classifiers' <<<"$out" \
  && bad "opus-4-8 vs sonnet: content-fallback caveat printed for models without it" \
  || ok "opus-4-8 vs sonnet: no content-fallback caveat"

# --- arm/judge same family (#391): a judge grading its own family's output skews the delta ---
# clean fixtures' judgeModel is "sonnet"; mismatch-b.json's is "haiku". Each arm is checked
# against its own file's judge.
out=$(python3 "$DIFF_PY" --label-a sonnet@high --label-b claude-opus-5-5 \
  "$FIXTURES/clean-a.json" "$FIXTURES/clean-b.json" 2>&1)
/usr/bin/grep -qF 'sonnet@high: arm shares the judge model family (sonnet)' <<<"$out" \
  && ok "same-family arm: WARN names the arm and the shared family" \
  || bad "same-family arm: no WARN for sonnet arm judged by sonnet"
/usr/bin/grep -qF 'claude-opus-5-5: arm shares' <<<"$out" \
  && bad "same-family arm: WARN fired for the opus arm against a sonnet judge" \
  || ok "same-family arm: no WARN for an arm of a different family"
out=$(python3 "$DIFF_PY" --label-a claude-sonnet-5 --label-b claude-haiku-4-5 \
  "$FIXTURES/clean-a.json" "$FIXTURES/mismatch-b.json" 2>&1)
/usr/bin/grep -qF 'claude-haiku-4-5: arm shares the judge model family (haiku)' <<<"$out" \
  && /usr/bin/grep -qF 'claude-sonnet-5: arm shares the judge model family (sonnet)' <<<"$out" \
  && ok "same-family arm: each arm checked against its own file's judge" \
  || bad "same-family arm: per-arm judge not used (haiku arm/haiku judge, sonnet arm/sonnet judge)"

# --- mismatched pair: judgeModel + caseFilter differ, must WARN not hard-fail ---
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/mismatch-b.json" 2>&1)
status=$?

if [ "$status" -eq 0 ]; then ok "mismatch pair: exit 0 (WARN, not fatal)"; else bad "mismatch pair: exit $status (expected 0)"; fi

/usr/bin/grep -qF 'judgeModel differs: fixture-a=sonnet vs fixture-b=haiku' <<<"$out" \
  && ok "mismatch pair: WARN on judgeModel sonnet vs haiku" \
  || bad "mismatch pair: judgeModel WARN missing or wrong"

/usr/bin/grep -qF 'caseFilter differs: fixture-a=model-bench-fixture vs fixture-b=all cases' <<<"$out" \
  && ok "mismatch pair: WARN on caseFilter set vs absent(default)" \
  || bad "mismatch pair: caseFilter WARN missing or wrong"

/usr/bin/grep -qF 'ablation differs: fixture-a=none vs fixture-b=with-without' <<<"$out" \
  && ok "mismatch pair: WARN on ablation none vs with-without" \
  || bad "mismatch pair: ablation WARN missing or wrong"

/usr/bin/grep -qF 'claudeVersion differs: fixture-a=2.1.270 vs fixture-b=2.1.275' <<<"$out" \
  && ok "mismatch pair: WARN on claudeVersion 2.1.270 vs 2.1.275" \
  || bad "mismatch pair: claudeVersion WARN missing or wrong"

/usr/bin/grep -qF "plugin version differs: fixture-a=['1.1.94'] vs fixture-b=['1.1.95']" <<<"$out" \
  && ok "mismatch pair: WARN on plugin version 1.1.94 vs 1.1.95" \
  || bad "mismatch pair: plugin version WARN missing or wrong"

# --- per-eval judge (GH #510): a judgeModel mismatch on a case evals/judge-models.tsv moves to
# another judge is expected, so the WARN says so; any other mismatch keeps the bare WARN ---
EXPECTED_NOTE='expected: perf-regression-routing is judged by sonnet (evals/judge-models.tsv: GH #510)'
out=$(python3 "$DIFF_PY" --judge-models "$FIXTURES/judge-models.tsv" --label-a haiku-history --label-b sonnet-rerun \
  "$FIXTURES/judge-override-haiku.json" "$FIXTURES/judge-override-sonnet.json" 2>&1)
/usr/bin/grep -qF "judgeModel differs: haiku-history=haiku (default) vs sonnet-rerun=sonnet — $EXPECTED_NOTE" <<<"$out" \
  && ok "per-eval judge: mismatch on a declared case is marked expected" \
  || bad "per-eval judge: declared-case mismatch not marked expected"
out=$(python3 "$DIFF_PY" --judge-models "$FIXTURES/judge-models.tsv" --label-a sonnet-rerun --label-b haiku-history \
  "$FIXTURES/judge-override-sonnet.json" "$FIXTURES/judge-override-haiku.json" 2>&1)
/usr/bin/grep -qF "$EXPECTED_NOTE" <<<"$out" \
  && ok "per-eval judge: marked expected with the declared judge on side A too" \
  || bad "per-eval judge: side-A declared judge not marked expected"
out=$(python3 "$DIFF_PY" --label-a haiku-history --label-b sonnet-rerun \
  "$FIXTURES/judge-override-haiku.json" "$FIXTURES/judge-override-sonnet.json" 2>&1)
/usr/bin/grep -qF "$EXPECTED_NOTE" <<<"$out" \
  && ok "per-eval judge: default --judge-models reads the repo's evals/judge-models.tsv" \
  || bad "per-eval judge: the repo's evals/judge-models.tsv was not read by default"
out=$(python3 "$DIFF_PY" --judge-models "$FIXTURES/judge-models.tsv" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/mismatch-b.json" 2>&1)
/usr/bin/grep -qF 'judgeModel differs' <<<"$out" && ! /usr/bin/grep -qF 'expected:' <<<"$out" \
  && ok "per-eval judge: undeclared cases keep the bare judgeModel WARN" \
  || bad "per-eval judge: undeclared cases: judgeModel WARN missing or marked expected"
out=$(python3 "$DIFF_PY" --judge-models "$FIXTURES/judge-models.tsv" --label-a sonnet-rerun --label-b opus-run \
  "$FIXTURES/judge-override-sonnet.json" "$FIXTURES/judge-override-opus.json" 2>&1)
/usr/bin/grep -qF 'judgeModel differs' <<<"$out" && ! /usr/bin/grep -qF 'expected:' <<<"$out" \
  && ok "per-eval judge: declared judge vs a non-haiku judge keeps the bare WARN" \
  || bad "per-eval judge: non-haiku other side: judgeModel WARN missing or marked expected"
out=$(python3 "$DIFF_PY" --judge-models "$TMP_MODELS.missing" --label-a haiku-history --label-b sonnet-rerun \
  "$FIXTURES/judge-override-haiku.json" "$FIXTURES/judge-override-sonnet.json" 2>&1)
status=$?
[ "$status" -ne 0 ] && /usr/bin/grep -qF 'no such file' <<<"$out" \
  && ok "per-eval judge: an explicit --judge-models path that does not exist is an error" \
  || bad "per-eval judge: missing explicit --judge-models path accepted (exit $status)"
printf '%s' '{"schemaVersion":1,"costUsd":0,"partial":false,"suite":{"judgeModel":"sonnet"},"aggregates":{"overallScore":0,"overallPassRate":0,"casesTotal":0},"cases":null}' > "$TMP_MODELS.null.json"
out=$(python3 "$DIFF_PY" --judge-models "$FIXTURES/judge-models.tsv" --label-a haiku-history --label-b null-cases \
  "$FIXTURES/judge-override-haiku.json" "$TMP_MODELS.null.json" 2>&1)
status=$?
[ "$status" -eq 0 ] && /usr/bin/grep -qF 'casesTotal is 0 on null-cases' <<<"$out" \
  && ok "per-eval judge: \"cases\": null still reports casesTotal 0, no crash" \
  || bad "per-eval judge: \"cases\": null crashed (exit $status): $out"
printf '# no rows\n' > "$TMP_MODELS"
out=$(python3 "$DIFF_PY" --judge-models "$TMP_MODELS" --label-a haiku-history --label-b sonnet-rerun \
  "$FIXTURES/judge-override-haiku.json" "$FIXTURES/judge-override-sonnet.json" 2>&1)
/usr/bin/grep -qF 'judgeModel differs' <<<"$out" && ! /usr/bin/grep -qF 'expected:' <<<"$out" \
  && ok "per-eval judge: no declaration, bare judgeModel WARN" \
  || bad "per-eval judge: no declaration: judgeModel WARN missing or marked expected"

# --- plugin-problem arm: must hard-fail, never print a comparison table ---
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/problem-b.json" 2>&1)
status=$?

if [ "$status" -eq 1 ]; then ok "plugin-problem arm: exit 1 (hard-fail)"; else bad "plugin-problem arm: exit $status (expected 1)"; fi
/usr/bin/grep -qF 'HARD-FAIL' <<<"$out" \
  && /usr/bin/grep -qF 'plugin problem: disabled_by_default' <<<"$out" \
  && ok "plugin-problem arm: HARD-FAIL names the plugin problem" \
  || bad "plugin-problem arm: HARD-FAIL message missing or wrong"
/usr/bin/grep -q 'overallScore\|score=' <<<"$out" \
  && bad "plugin-problem arm: printed score numbers despite hard-fail (numbers would be misleading)" \
  || ok "plugin-problem arm: no score table printed alongside the hard-fail"

# --- partial arm: must hard-fail, never print a comparison table ---
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/partial-b.json" 2>&1)
status=$?

if [ "$status" -eq 1 ]; then ok "partial arm: exit 1 (hard-fail)"; else bad "partial arm: exit $status (expected 1)"; fi
/usr/bin/grep -qF 'HARD-FAIL' <<<"$out" \
  && /usr/bin/grep -qF 'partial run (reason: test-interrupted)' <<<"$out" \
  && ok "partial arm: HARD-FAIL names the partialReason" \
  || bad "partial arm: HARD-FAIL message missing or wrong"
/usr/bin/grep -q 'overallScore\|score=' <<<"$out" \
  && bad "partial arm: printed score numbers despite hard-fail (numbers would be misleading)" \
  || ok "partial arm: no score table printed alongside the hard-fail"

# --- zero-case arm: explicit note, no divide-by-zero crash ---
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/zero-cases.json" 2>&1)
status=$?

if [ "$status" -eq 0 ]; then ok "zero-case arm: exit 0"; else bad "zero-case arm: exit $status (expected 0)"; fi
/usr/bin/grep -qF 'casesTotal is 0' <<<"$out" \
  && ok "zero-case arm: explicit note instead of a crash or misleading 0-vs-0 table" \
  || bad "zero-case arm: missing the casesTotal==0 note"

# --- missing-casesTotal arm: WARN like the other always-present fields, still render per-case ---
# 2026-09-21 deep-audit: a deleted aggregates.casesTotal read as 0 and skipped the per-case
# table while cases[] had entries -- the exact silent-zero the docstring says is guarded.
out=$(python3 "$DIFF_PY" --label-a fixture-a --label-b fixture-b \
  "$FIXTURES/clean-a.json" "$FIXTURES/no-cases-total-b.json" 2>&1)
status=$?

if [ "$status" -eq 0 ]; then ok "missing-casesTotal arm: exit 0"; else bad "missing-casesTotal arm: exit $status (expected 0)"; fi
/usr/bin/grep -qF "fixture-b: 'casesTotal' missing" <<<"$out" \
  && ok "missing-casesTotal arm: WARN names the missing field" \
  || bad "missing-casesTotal arm: no WARN for the missing casesTotal"
/usr/bin/grep -qF 'shared-skill-case' <<<"$out" \
  && /usr/bin/grep -qF '+0.050' <<<"$out" \
  && ok "missing-casesTotal arm: per-case table still rendered from cases[]" \
  || bad "missing-casesTotal arm: per-case table skipped despite cases[] having entries"
/usr/bin/grep -qF 'casesTotal is 0' <<<"$out" \
  && bad "missing-casesTotal arm: printed the casesTotal==0 note for a file that has cases" \
  || ok "missing-casesTotal arm: no misleading casesTotal==0 note"

echo "model-bench-diff.py self-test: $pass passed, $fail failed"

# --- model-bench.sh argv/env self-test: stub `claude` on PATH, never runs anything real ---
# 2026-09-25: model@effort arm syntax sets CLAUDE_CODE_EFFORT_LEVEL per arm (the CLI's own
# --effort flag was verified live to never reach an eval child; that env var does). Assert the
# actual invocation shape, not just that the script runs.
echo "=== model-bench.sh argv/env self-test ==="

MODEL_BENCH="$ROOT/skills/meta/model-bench/scripts/model-bench.sh"
STUB_DIR="$(mktemp -d)"
CLAUDE_STUB_LOG="$(mktemp)"
export CLAUDE_STUB_LOG
BENCH_DIRS_BEFORE="$(python3 -c "import os; print(' '.join(sorted(d for d in os.listdir('$ROOT/evals/results') if d.startswith('model-bench-'))) if os.path.isdir('$ROOT/evals/results') else '')" 2>/dev/null)"

cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "2.1.999 (Claude Code, stub)"; exit 0; fi
model=""; out_dir=""; prev=""
for a in "$@"; do
  case "$prev" in --model) model="$a" ;; --output-dir) out_dir="$a" ;; esac
  prev="$a"
done
echo "MODEL=$model EFFORT=${CLAUDE_CODE_EFFORT_LEVEL:-<unset>} ARGV=$*" >> "$CLAUDE_STUB_LOG"
if [ -n "$out_dir" ]; then
  mkdir -p "$out_dir"
  printf '%s' '{"schemaVersion":1,"costUsd":0,"claudeVersion":"2.1.999","partial":false,"suite":{"judgeModel":"haiku","caseFilter":null,"ablation":"none","plugins":[]},"aggregates":{"overallScore":1,"overallPassRate":1,"casesTotal":0},"cases":[]}' \
    > "$out_dir/aggregate-result.json"
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

unset CLAUDE_CODE_EFFORT_LEVEL
: > "$CLAUDE_STUB_LOG"
out=$(PATH="$STUB_DIR:$PATH" bash "$MODEL_BENCH" sonnet@high opus --no-publish 2>&1)
status=$?

if [ "$status" -eq 0 ]; then ok "sonnet@high vs opus: exit 0"; else bad "sonnet@high vs opus: exit $status (expected 0) -- $out"; fi
/usr/bin/grep -qF 'MODEL=sonnet EFFORT=high ' "$CLAUDE_STUB_LOG" \
  && ok "sonnet@high: CLAUDE_CODE_EFFORT_LEVEL=high set for that arm's claude call" \
  || bad "sonnet@high: effort not set to high in the claude invocation"
/usr/bin/grep -qF 'MODEL=opus EFFORT=<unset> ' "$CLAUDE_STUB_LOG" \
  && ok "bare opus: no CLAUDE_CODE_EFFORT_LEVEL set (unchanged from today)" \
  || bad "bare opus: effort env var was set when it should be absent"
/usr/bin/grep -qF 'sonnet@high' <<<"$out" \
  && ok "report label is the full 'sonnet@high' spec, not the bare model name" \
  || bad "report label missing the @effort suffix"

for bad_spec in '@high' 'sonnet@' 'sonnet@high@extra' 'sonnet@bogus'; do
  : > "$CLAUDE_STUB_LOG"
  PATH="$STUB_DIR:$PATH" bash "$MODEL_BENCH" "$bad_spec" opus >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 1 ] && [ ! -s "$CLAUDE_STUB_LOG" ]; then
    ok "malformed spec '$bad_spec': rejected (exit 1) before any claude invocation"
  else
    bad "malformed spec '$bad_spec': exit $status, stub log size $(wc -c < "$CLAUDE_STUB_LOG") (expected exit 1, empty log)"
  fi
done

: > "$CLAUDE_STUB_LOG"
PATH="$STUB_DIR:$PATH" bash "$MODEL_BENCH" sonnet opus -- --tag smoke >/dev/null 2>&1
/usr/bin/grep -qF -- '--tag smoke' "$CLAUDE_STUB_LOG" \
  && ok "passthrough args after -- reach the claude invocation, not parsed as arm syntax" \
  || bad "passthrough args after -- did not reach the claude invocation"

python3 -c "
import os
root = '$ROOT/evals/results'
before = set('$BENCH_DIRS_BEFORE'.split())
if os.path.isdir(root):
    for d in os.listdir(root):
        if d.startswith('model-bench-') and d not in before:
            print(os.path.join(root, d))
" | while IFS= read -r stray; do trash "$stray" 2>/dev/null; done

tmp_delete "$STUB_DIR" "$CLAUDE_STUB_LOG" "$TMP_MODELS" "$TMP_MODELS.null.json"

echo "model-bench.sh self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
