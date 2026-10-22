#!/usr/bin/env bash
# mh:ideate ranker: the weighted total, ordering, top-K, runner-up and non-obvious
# pick are computed in code, never by the critic agent by hand.
# Run standalone: bash tests/skills/test-ideate-rank.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$ROOT/skills/workflow/ideate/scripts/rank.py" --selftest || { echo "FAIL: rank.py selftest"; exit 1; }
out=$(printf '%s' '{"topK":1,"scores":{"x":{"novelty":7,"viability":6,"fit":8,"trap":null}}}' | python3 "$ROOT/skills/workflow/ideate/scripts/rank.py")
echo "$out" | /usr/bin/grep -q '"x": 6.85' || { echo "FAIL: stdin path, got: $out"; exit 1; }
# 2026-09-21 deep-audit: topK < 1 or non-integer must fail closed with empty stdout.
for bad_k in -1 0 null true; do
  k_out=$(printf '%s' "{\"topK\":$bad_k,\"scores\":{\"x\":{\"novelty\":7,\"viability\":6,\"fit\":8,\"trap\":null}}}" | python3 "$ROOT/skills/workflow/ideate/scripts/rank.py" 2>/dev/null)
  k_code=$?
  [ "$k_code" -eq 1 ] || { echo "FAIL: expected exit 1 on topK=$bad_k, got $k_code"; exit 1; }
  [ -z "$k_out" ] || { echo "FAIL: expected empty stdout on topK=$bad_k, got: $k_out"; exit 1; }
done
# Malformed shapes and a duplicate idea ID fail closed: rc 1, a rank.py: reason, no traceback.
X='{"novelty":7,"viability":6,"fit":8,"trap":null}'
for bad in '[]' '{"scores":[]}' '{"scores":{"a":5}}' "{\"scores\":{\"a\":$X,\"a\":$X}}"; do
  err=$(printf '%s' "$bad" | python3 "$ROOT/skills/workflow/ideate/scripts/rank.py" 2>&1 >/dev/null)
  code=$?
  [ "$code" -eq 1 ] || { echo "FAIL: expected exit 1 on $bad, got $code"; exit 1; }
  case "$err" in *Traceback*) echo "FAIL: traceback on $bad: $err"; exit 1;; esac
  case "$err" in "rank.py: "*) ;; *) echo "FAIL: no rank.py: reason on $bad: $err"; exit 1;; esac
done
echo "PASS: test-ideate-rank"
