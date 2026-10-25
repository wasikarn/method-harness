#!/usr/bin/env bash
# scripts/_lib/weighted-score.py: shared deep-audit/idea-audit scorer.
# Renormalization must differ from divide-by-full-weight-sum (equivalent to
# scoring a dropped dimension 0), and malformed input must fail closed.
# Run standalone: bash tests/skills/test-weighted-score.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCORER="$ROOT/scripts/_lib/weighted-score.py"

python3 "$SCORER" --selftest || { echo "FAIL: weighted-score.py selftest"; exit 1; }

# Full-rubric total via stdin, matching deep-audit's 5-dim shape.
out=$(python3 "$SCORER" <<'EOF'
{"scores": [
  {"id": "correctness", "score": 8, "max": 10, "weight": 3, "insufficient": false},
  {"id": "completeness", "score": 7, "max": 10, "weight": 2, "insufficient": false},
  {"id": "claim_accuracy", "score": 9, "max": 10, "weight": 2, "insufficient": false},
  {"id": "regression_safety", "score": 6, "max": 10, "weight": 2, "insufficient": false},
  {"id": "simplicity", "score": 8, "max": 10, "weight": 1, "insufficient": false}
], "floorPct": 0.5, "passThreshold": 7.0}
EOF
)
/usr/bin/grep -q '"total": 7.6' <<<"$out" || { echo "FAIL: stdin total, got: $out"; exit 1; }
/usr/bin/grep -q '"pass": true' <<<"$out" || { echo "FAIL: stdin pass, got: $out"; exit 1; }

# Malformed input (all insufficient) must exit non-zero and print no JSON on stdout.
bad_out=$(printf '%s' '{"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1, "insufficient": true}]}' | python3 "$SCORER" 2>/dev/null)
bad_code=$?
[ "$bad_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on all-insufficient input"; exit 1; }
[ -z "$bad_out" ] || { echo "FAIL: expected empty stdout on rejected input, got: $bad_out"; exit 1; }

# A duplicate id must fail closed, not silently collapse in the primaryId
# weights dict and defeat the strictly-greatest check (idea-audit's
# never-tied-for-first rule).
dup_out=$(printf '%s' '{"scores": [{"id": "a", "score": 8, "max": 10, "weight": 40, "insufficient": false}, {"id": "b", "score": 7, "max": 10, "weight": 30, "insufficient": false}, {"id": "b", "score": 7, "max": 10, "weight": 40, "insufficient": false}], "primaryId": "a"}' | python3 "$SCORER" 2>/dev/null)
dup_code=$?
[ "$dup_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on duplicate id"; exit 1; }
[ -z "$dup_out" ] || { echo "FAIL: expected empty stdout on duplicate-id input, got: $dup_out"; exit 1; }

# A non-finite score must fail closed, not emit the literal (invalid-JSON)
# token Infinity and flip a failing rubric to pass:true.
inf_out=$(python3 -c 'import json; print(json.dumps({"scores": [{"id": "a", "score": float("inf"), "max": 10, "weight": 3, "insufficient": False}, {"id": "b", "score": 3, "max": 10, "weight": 2, "insufficient": False}], "passThreshold": 7.0}))' | python3 "$SCORER" 2>/dev/null)
inf_code=$?
[ "$inf_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on Infinity score"; exit 1; }
[ -z "$inf_out" ] || { echo "FAIL: expected empty stdout on Infinity score, got: $inf_out"; exit 1; }

# A boolean score must fail closed, not silently coerce to 1/0 (bool is an
# int subclass in Python).
bool_out=$(printf '%s' '{"scores": [{"id": "a", "score": true, "max": 10, "weight": 3, "insufficient": false}, {"id": "b", "score": 5, "max": 10, "weight": 2, "insufficient": false}]}' | python3 "$SCORER" 2>/dev/null)
bool_code=$?
[ "$bool_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on boolean score"; exit 1; }
[ -z "$bool_out" ] || { echo "FAIL: expected empty stdout on boolean score, got: $bool_out"; exit 1; }

# Floor boundary: a score exactly at floorPct * max must not trip
# belowFloor -- the check is strictly '<', discriminating a future '<='
# regression.
floor_out=$(printf '%s' '{"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1, "insufficient": false}], "floorPct": 0.5}' | python3 "$SCORER")
/usr/bin/grep -q '"belowFloor": \[\]' <<<"$floor_out" || { echo "FAIL: score at exact floor tripped belowFloor, got: $floor_out"; exit 1; }

# Weight-sensitivity: research-doc row 5 (8/10/3) is a fragile fail via stdin.
sens_out=$(python3 "$SCORER" <<'EOF'
{"scores": [
  {"id": "ev", "score": 8, "max": 10, "weight": 3, "insufficient": false},
  {"id": "ease", "score": 10, "max": 10, "weight": 3.5, "insufficient": false},
  {"id": "val", "score": 3, "max": 10, "weight": 3.5, "insufficient": false}
], "passThreshold": 7.0, "perturb": 0.2}
EOF
)
/usr/bin/grep -q '"verdictStable": false' <<<"$sens_out" || { echo "FAIL: expected fragile verdictStable, got: $sens_out"; exit 1; }
/usr/bin/grep -q '6.36' <<<"$sens_out" || { echo "FAIL: expected totalRange lo 6.36, got: $sens_out"; exit 1; }

# An out-of-range perturb must fail closed with empty stdout, same as any
# other malformed input -- including the >=1 fail-open this repo's own
# review found (a perturbed weight going <=0 without raising).
for bad_p in 0 1 1.5 2.5; do
  p_out=$(printf '%s' "{\"scores\": [{\"id\": \"x\", \"score\": 5, \"max\": 10, \"weight\": 1, \"insufficient\": false}, {\"id\": \"y\", \"score\": 5, \"max\": 10, \"weight\": 1, \"insufficient\": false}], \"perturb\": $bad_p}" | python3 "$SCORER" 2>/dev/null)
  p_code=$?
  [ "$p_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on perturb=$bad_p"; exit 1; }
  [ -z "$p_out" ] || { echo "FAIL: expected empty stdout on perturb=$bad_p, got: $p_out"; exit 1; }
done

# Omitting perturb must not add a "sensitivity" key -- backward compatibility.
noperturb_out=$(printf '%s' '{"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1, "insufficient": false}]}' | python3 "$SCORER")
/usr/bin/grep -q 'sensitivity' <<<"$noperturb_out" && { echo "FAIL: unexpected sensitivity key with no perturb input, got: $noperturb_out"; exit 1; }

# A string "false" in `insufficient` is truthy -- it must fail closed, not
# silently drop a 0/10 axis from belowFloor (2026-09-21 deep-audit).
str_out=$(printf '%s' '{"scores": [{"id": "a", "score": 0, "max": 10, "weight": 1, "insufficient": "false"}, {"id": "b", "score": 8, "max": 10, "weight": 1, "insufficient": false}], "floorPct": 0.5}' | python3 "$SCORER" 2>/dev/null)
str_code=$?
[ "$str_code" -ne 0 ] || { echo "FAIL: expected non-zero exit on string insufficient"; exit 1; }
[ -z "$str_out" ] || { echo "FAIL: expected empty stdout on string insufficient, got: $str_out"; exit 1; }

# A non-object payload (a JSON list) must fail with the one-line stderr
# reason, never an AttributeError traceback.
list_err=$(printf '%s' '[{"id": "a", "score": 5, "max": 10, "weight": 1, "insufficient": false}]' | python3 "$SCORER" 2>&1 >/dev/null)
list_code=$?
[ "$list_code" -eq 1 ] || { echo "FAIL: expected exit 1 on list payload, got $list_code"; exit 1; }
/usr/bin/grep -q '^weighted-score: ' <<<"$list_err" || { echo "FAIL: expected one-line weighted-score: reason on list payload, got: $list_err"; exit 1; }
/usr/bin/grep -q 'Traceback' <<<"$list_err" && { echo "FAIL: list payload leaked a traceback: $list_err"; exit 1; }

echo "PASS: test-weighted-score"
