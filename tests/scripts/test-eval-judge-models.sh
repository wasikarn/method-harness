#!/usr/bin/env bash
# test-eval-judge-models.sh — exercises scripts/_lib/eval_judge_models.py, the reader of
# evals/judge-models.tsv (GH #510: per-eval judge model, since `claude plugin eval` only takes a
# run-wide --judge-model). Checks the real sidecar is valid and names perf-regression-routing ->
# sonnet, that `for-tag` matches any tag a case carries (as the CLI's --tag does), and that a
# malformed sidecar is refused rather than silently judged by haiku.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$ROOT/scripts/_lib/tmp-delete.sh"
PY="$ROOT/scripts/_lib/eval_judge_models.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
TMP=$(mktemp -d)
trap 'tmp_delete "$TMP"' EXIT

echo "=== eval_judge_models.py self-test ==="

python3 "$PY" check >/dev/null 2>&1 \
  && ok "real evals/judge-models.tsv passes check" \
  || bad "real evals/judge-models.tsv fails check: $(python3 "$PY" check 2>&1)"

out=$(python3 "$PY" for-tag performance-optimizer 2>&1)
[ "$out" = "$(printf 'perf-regression-routing\tsonnet\tBash,Read,Write,Edit,Grep,Glob,Agent,Skill')" ] \
  && ok "for-tag performance-optimizer: perf-regression-routing judged by sonnet, with its own allowed_tools" \
  || bad "for-tag performance-optimizer: got '$out'"

out=$(python3 "$PY" for-tag clean 2>&1)
[ "$out" = "$(printf 'perf-regression-routing\tsonnet\tBash,Read,Write,Edit,Grep,Glob,Agent,Skill')" ] \
  && ok "for-tag clean: a non-first tag matches too (the CLI's --tag matches any tag)" \
  || bad "for-tag clean: got '$out'"

out=$(python3 "$PY" for-tag code-architect 2>&1)
[ -z "$out" ] \
  && ok "for-tag code-architect: no override, prints nothing" \
  || bad "for-tag code-architect: got '$out'"

# Fixture evals dir: one case with tags, then each malformed sidecar must fail check.
mkdir -p "$TMP/evals/demo-case"
printf -- '---\nname: demo-case\ntags: [demo, clean]\n---\nask\n' > "$TMP/evals/demo-case/prompt.md"
expect_bad() {  # <label> <tsv body>
  printf '%b' "$2" > "$TMP/evals/judge-models.tsv"
  if python3 "$PY" check --evals "$TMP/evals" >/dev/null 2>&1; then
    bad "check accepts $1"
  else
    ok "check refuses $1"
  fi
}
expect_bad "an unknown case" 'no-such-case\tsonnet\tGH #1\n'
expect_bad "a duplicate case" 'demo-case\tsonnet\tGH #1\ndemo-case\topus\tGH #2\n'
expect_bad "an empty model" 'demo-case\t\tGH #1\n'
expect_bad "a missing reason" 'demo-case\tsonnet\n'
expect_bad "a haiku row (the default, so a no-op)" 'demo-case\thaiku\tGH #1\n'
expect_bad "a haiku-family model id (also the default)" 'demo-case\tclaude-haiku-4-5\tGH #1\n'
expect_bad "a model naming no known family (a typo)" 'demo-case\tsonet\tGH #1\n'
expect_bad "shell code in the model (it would run from the printed bash -c line)" 'demo-case\tsonnet$(touch${IFS}PWNED)\tGH #1\n'
expect_bad "a relative path in the case column" '../evals/demo-case\tsonnet\tGH #1\n'
expect_bad "an absolute path in the case column" "$TMP/evals/demo-case\tsonnet\tGH #1\n"
expect_bad "a quote in the model" "demo-case\tsonnet'x\tGH #1\n"
expect_bad "a space in the model" 'demo-case\tson net\tGH #1\n'
# GH #788: eval-changed.sh quotes each printed argument, so a context-window suffix or a Bedrock
# ARN is allowed in the model column.
for m in 'opus[1m]' 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-v1:0'; do
  printf 'demo-case\t%s\tGH #1\n' "$m" > "$TMP/evals/judge-models.tsv"
  python3 "$PY" check --evals "$TMP/evals" >/dev/null 2>&1 && ok "check accepts model $m" \
    || bad "check refuses model $m: $(python3 "$PY" check --evals "$TMP/evals" 2>&1)"
done
printf 'a..b\tsonnet\tGH #1\n' > "$TMP/evals/judge-models.tsv"; mkdir -p "$TMP/evals/a..b"; cp "$TMP/evals/demo-case/prompt.md" "$TMP/evals/a..b/"
python3 "$PY" check --evals "$TMP/evals" >/dev/null 2>&1 \
  && ok "check accepts a dir name with '..' inside it (the case pattern already bars paths)" \
  || bad "check refuses a..b: $(python3 "$PY" check --evals "$TMP/evals" 2>&1)"

printf '# comment\n  # indented comment\n\ndemo-case\tsonnet\tGH #1\n' > "$TMP/evals/judge-models.tsv"
python3 "$PY" check --evals "$TMP/evals" >/dev/null 2>&1 \
  && ok "check accepts comments, blank lines and a valid row" \
  || bad "check refuses a valid fixture sidecar"
printf '\xef\xbb\xbf# comment after a BOM\ndemo-case\tsonnet\tGH #1\n' > "$TMP/evals/judge-models.tsv"
python3 "$PY" check --evals "$TMP/evals" >/dev/null 2>&1 \
  && ok "check accepts a file that starts with a UTF-8 BOM" \
  || bad "check refuses a BOM-prefixed sidecar: $(python3 "$PY" check --evals "$TMP/evals" 2>&1)"
printf 'demo-case\tsonnet\tGH #1\n' > "$TMP/evals/judge-models.tsv"
out=$(python3 "$PY" for-tag demo --evals "$TMP/evals" 2>&1)
[ "$out" = "$(printf 'demo-case\tsonnet\t')" ] \
  && ok "for-tag reads the --evals dir's sidecar" \
  || bad "for-tag --evals: got '$out'"

echo "eval_judge_models.py self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
