#!/usr/bin/env python3
"""Deterministic weighted scorer for mh:deep-audit and mh:idea-audit.

stdin:  {"scores": [{"id": str, "score": num, "max": num, "weight": num,
                      "insufficient": bool}, ...],
         "floorPct": 0-1, "passThreshold": num | omitted, "primaryId": str | omitted,
         "perturb": 0<p<1 | omitted}
stdout: {"total": float, "weightSum": float, "belowFloor": [id...],
         "pass": bool | null, "primaryWeightOk": bool | null,
         "sensitivity": {"perturb": num, "totalRange": [lo, hi],
                          "verdictStable": bool | null} | omitted}

An optional `perturb` runs a weight-sensitivity check: every SCORED weight is
independently moved +/-perturb (renormalized -- see _sensitivity's docstring
for why this is exact, not sampled) and the resulting min/max `total` is
reported as `totalRange`. `verdictStable` says whether `pass` can change
anywhere in that box; it is `null` when no `passThreshold` was given (ranges
alone are still meaningful, e.g. for mh:idea-audit).

Known limitation, found by mh:deep-audit 2026-09-20: `primaryWeightOk` is
computed once, from the original unperturbed weights; `sensitivity`'s corners
do not check whether a perturbation could make the primary axis stop being
the single largest weight. No current caller passes both `primaryId` and
`perturb` in the same call (mh:idea-audit, the only `primaryId` user, does
not opt into `perturb` for v1) -- if one ever does, `primaryWeightOk: true`
would not guarantee the invariant holds at every reported corner.

The model scores each dimension and writes reasons; this script does the
arithmetic (weighted total, floor check, pass/fail) so a wrong hand sum or a
hand-renormalized total can never reach a Final Verdict. Mirrors
skills/workflow/ideate/scripts/rank.py's contract and --selftest convention.

An `insufficient`-flagged item is dropped from both the numerator and the
denominator, so `total` renormalizes over the weights that actually scored
-- never divides by the full declared weight sum, which would be
arithmetically identical to scoring the dropped item 0.

Fails closed: any input this script cannot compute (a non-object payload, a
missing/non-numeric field, a bool or non-finite score/max/weight, a non-bool
`insufficient` -- the string "false" is truthy, a non-positive max or negative
weight, a duplicate id, every item flagged insufficient, or the `primaryId`
item itself flagged insufficient) exits 1 with a one-line reason on stderr
and prints no JSON. The last case matters because `insufficient` items are
dropped from the total's numerator/denominator (see below) with no separate
signal -- for an ordinary axis that's a fair renormalization, but for the
axis a caller declared `primaryId` (the one that "can't be diluted to
parity" per mh:idea-audit's own Rule 5 rationale) it would silently produce
a complete-looking total with the single most load-bearing axis missing.
Found by mh:deep-audit 2026-09-19, when idea-audit still omitted
`passThreshold`, so nothing downstream was catching this case either.
The caller must treat that as a hard fail, never as license to score by hand.
"""
import json
import math
import sys
from typing import NoReturn


def _die(reason: str) -> NoReturn:
    print(f"weighted-score: {reason}", file=sys.stderr)
    sys.exit(1)


MAX_PERTURB_AXES = 12  # 2**12 = 4096 corners; above this, fail closed rather than stall


def _sensitivity(items, weight_sum, below_floor, perturb, pass_threshold):
    """Exact min/max of `total` when every SCORED weight independently moves
    +/-perturb, holding the original `weight_sum` fixed as the external
    multiplier (never recomputed from the perturbed vector).

    Only relative weight among the SCORED items can move `total` -- weight_sum
    is a fixed scaling constant here, not something perturbation redistributes,
    so `total`'s new value is exactly (sum of r_i*w_i') / (sum of w_i') *
    weight_sum for the perturbed scored weights w_i'. An `insufficient` item's
    weight never enters that ratio, so perturbing it is a provable no-op, not
    an approximation -- it is excluded from both the corner enumeration and
    the axis-count cap below. A weight-0 item is the same no-op for the same
    reason (0 * any factor is still 0) and is excluded alongside it -- found
    by mh:deep-audit 2026-09-20: without this, a placeholder weight-0 axis
    could push an otherwise-fine score over MAX_PERTURB_AXES and fail closed.

    Corners, not a random search: for fixed weight_sum, `total` as a function
    of the scored weights is a ratio of two functions linear in those weights
    (linear-fractional, hence quasilinear), so its extrema over the +/-perturb
    box are exactly at the box's 2**n vertices -- deterministic, no PRNG, same
    "deterministic script" contract rank.py/plan-verdict-check.py already hold.
    """
    if (isinstance(perturb, bool) or not isinstance(perturb, (int, float))
            or not math.isfinite(perturb) or not 0 < perturb < 1):
        _die(f"'perturb' must be a finite number strictly between 0 and 1, got {perturb!r}")
    scored = [(it["score"] / it["max"], it["weight"])
              for it in items
              if not bool(it.get("insufficient", False)) and it["weight"] != 0]
    n = len(scored)
    if n > MAX_PERTURB_AXES:
        _die(f"'perturb' over {n} scored axes needs 2**{n} corners; cap is {MAX_PERTURB_AXES}")
    lo = hi = None
    for corner in range(2 ** n):
        raw = 0.0
        wsum = 0.0
        for i, (ratio, w) in enumerate(scored):
            factor = (1 + perturb) if (corner >> i) & 1 else (1 - perturb)
            wp = w * factor
            raw += ratio * wp
            wsum += wp
        # wsum == 0 only if every scored weight is 0, which score()'s own
        # scored_weight_sum == 0 check already rejects before this runs.
        t = round(raw / wsum * weight_sum, 2)
        lo = t if lo is None or t < lo else lo
        hi = t if hi is None or t > hi else hi
    verdict_stable = None
    if pass_threshold is not None:
        # below_floor is a per-axis (s/m) < floorPct test -- weight-independent,
        # so a floor-pinned pass=False can never flip no matter how weights move.
        verdict_stable = True if below_floor else (lo >= pass_threshold or hi < pass_threshold)
    return {"perturb": perturb, "totalRange": [lo, hi], "verdictStable": verdict_stable}


def score(payload):
    if not isinstance(payload, dict):
        _die(f"payload must be a JSON object, got {type(payload).__name__}")
    items = payload.get("scores")
    if not isinstance(items, list) or not items:
        _die("'scores' must be a non-empty list")
    weight_sum = 0.0
    scored_weight_sum = 0.0
    raw_sum = 0.0
    below_floor = []
    floor_pct = payload.get("floorPct", 0.0)
    if (isinstance(floor_pct, bool) or not isinstance(floor_pct, (int, float))
            or not math.isfinite(floor_pct) or not 0 <= floor_pct <= 1):
        _die(f"'floorPct' must be a finite number between 0 and 1, got {floor_pct!r}")
    primary_id = payload.get("primaryId")
    primary_insufficient = False
    seen_ids = set()
    for it in items:
        try:
            item_id, s, m, w = it["id"], it["score"], it["max"], it["weight"]
            insufficient = it.get("insufficient", False)
        except (KeyError, TypeError):
            _die(f"malformed score entry: {it!r}")
        if not isinstance(insufficient, bool):
            _die(f"'insufficient' must be a bool, not {insufficient!r}: {it!r}")
        for x in (s, m, w):
            if isinstance(x, bool) or not isinstance(x, (int, float)):
                _die(f"score/max/weight must be numeric, not bool: {it!r}")
            if isinstance(x, float) and not math.isfinite(x):
                _die(f"score/max/weight must be finite: {it!r}")
        if m <= 0:
            _die(f"'{item_id}': max must be positive, got {m}")
        if w < 0:
            _die(f"'{item_id}': weight must be non-negative, got {w}")
        if not (0 <= s <= m):
            _die(f"'{item_id}': score must be within [0, max], got score={s} max={m}")
        if item_id in seen_ids:
            _die(f"duplicate id '{item_id}' in scores")
        seen_ids.add(item_id)
        weight_sum += w
        if insufficient:
            if item_id == primary_id:
                primary_insufficient = True
            continue
        scored_weight_sum += w
        raw_sum += (s / m) * w
        if (s / m) < floor_pct:
            below_floor.append(item_id)
    if scored_weight_sum == 0:
        _die("every item is insufficient evidence; cannot compute a total")
    if primary_insufficient:
        _die(f"primaryId '{primary_id}' is insufficient evidence; a total that drops the "
             f"single largest-weighted axis and renormalizes over the rest is not a "
             f"meaningful score, it's the floor tripping under another name")
    total = round(raw_sum / scored_weight_sum * weight_sum, 2)

    pass_threshold = payload.get("passThreshold")
    if pass_threshold is not None and (isinstance(pass_threshold, bool)
            or not isinstance(pass_threshold, (int, float)) or not math.isfinite(pass_threshold)):
        _die(f"'passThreshold' must be a finite number, got {pass_threshold!r}")
    verdict = None
    if pass_threshold is not None:
        verdict = total >= pass_threshold and not below_floor

    primary_ok = None
    if primary_id is not None:
        weights = {it["id"]: it["weight"] for it in items}
        if primary_id not in weights:
            _die(f"primaryId '{primary_id}' not found among scores")
        primary_w = weights[primary_id]
        primary_ok = all(primary_w > w for pid, w in weights.items() if pid != primary_id)

    out = {"total": total, "weightSum": weight_sum, "belowFloor": below_floor,
           "pass": verdict, "primaryWeightOk": primary_ok}
    if "perturb" in payload:
        out["sensitivity"] = _sensitivity(items, weight_sum, below_floor,
                                           payload["perturb"], pass_threshold)
    return out


def _selftest():
    dims = [
        {"id": "correctness", "score": 8, "max": 10, "weight": 3, "insufficient": False},
        {"id": "completeness", "score": 7, "max": 10, "weight": 2, "insufficient": False},
        {"id": "claim_accuracy", "score": 9, "max": 10, "weight": 2, "insufficient": False},
        {"id": "regression_safety", "score": 6, "max": 10, "weight": 2, "insufficient": False},
        {"id": "simplicity", "score": 8, "max": 10, "weight": 1, "insufficient": False},
    ]
    out = score({"scores": dims, "floorPct": 0.5, "passThreshold": 7.0})
    assert out["total"] == 7.6, out["total"]
    assert out["belowFloor"] == []
    assert out["pass"] is True

    # Mark regression_safety insufficient: renormalized total must differ from
    # the divide-by-full-weight-sum value (which equals scoring it 0 -> 6.4).
    dims_partial = [dict(d) for d in dims]
    dims_partial[3] = {**dims_partial[3], "insufficient": True}
    out2 = score({"scores": dims_partial, "floorPct": 0.5, "passThreshold": 7.0})
    assert out2["total"] == 8.0, out2["total"]  # renormalized: (2.4+1.4+1.8+0.8)/8*10
    wrong_divide_by_full = round(sum(
        (d["score"] / d["max"]) * d["weight"] for d in dims if d["id"] != "regression_safety"
    ), 2)
    assert wrong_divide_by_full == 6.4 and wrong_divide_by_full != out2["total"]

    # Floor trip: a scored (not insufficient) dim under floorPct of its own max.
    dims_low = [dict(d) for d in dims]
    dims_low[4] = {**dims_low[4], "score": 4}  # 4/10 = 0.4 < 0.5 floor
    out3 = score({"scores": dims_low, "floorPct": 0.5, "passThreshold": 7.0})
    assert out3["belowFloor"] == ["simplicity"]
    assert out3["pass"] is False

    # All-insufficient must fail closed, not divide by zero.
    try:
        score({"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1, "insufficient": True}]})
        raise AssertionError("expected SystemExit on all-insufficient input")
    except SystemExit as e:
        assert e.code == 1

    # Malformed input (max <= 0) fails closed, not with a ZeroDivisionError.
    try:
        score({"scores": [{"id": "x", "score": 5, "max": 0, "weight": 1, "insufficient": False}]})
        raise AssertionError("expected SystemExit on max<=0")
    except SystemExit as e:
        assert e.code == 1

    # primaryId strictly-greatest check (idea-audit's never-tied-for-first rule).
    axes = [
        {"id": "fidelity", "score": 80, "max": 100, "weight": 40, "insufficient": False},
        {"id": "fit", "score": 70, "max": 100, "weight": 30, "insufficient": False},
        {"id": "risk", "score": 60, "max": 100, "weight": 30, "insufficient": False},
    ]
    assert score({"scores": axes, "primaryId": "fidelity"})["primaryWeightOk"] is True
    axes_tied = [dict(a) for a in axes]
    axes_tied[1] = {**axes_tied[1], "weight": 40}
    assert score({"scores": axes_tied, "primaryId": "fidelity"})["primaryWeightOk"] is False

    # The primaryId axis marked insufficient must fail closed, not silently
    # renormalize the total over the remaining axes as if the primary axis
    # never existed -- the single largest-weighted axis vanishing without a
    # trace is the floor tripping under another name.
    axes_primary_insufficient = [dict(a) for a in axes]
    axes_primary_insufficient[0] = {**axes_primary_insufficient[0], "insufficient": True}
    try:
        score({"scores": axes_primary_insufficient, "primaryId": "fidelity"})
        raise AssertionError("expected SystemExit when the primaryId axis is insufficient")
    except SystemExit as e:
        assert e.code == 1

    # A non-primary axis marked insufficient must NOT trip this new check --
    # only ever hits the ordinary renormalization path.
    axes_other_insufficient = [dict(a) for a in axes]
    axes_other_insufficient[1] = {**axes_other_insufficient[1], "insufficient": True}
    out_other = score({"scores": axes_other_insufficient, "primaryId": "fidelity"})
    assert out_other["primaryWeightOk"] is True, out_other

    # A duplicate id must not be silently allowed to defeat the strictly-
    # greatest check by collapsing to one entry in the weights dict.
    axes_dup = axes + [{**axes[1], "weight": 40}]  # second "fit" entry, tied weight
    try:
        score({"scores": axes_dup, "primaryId": "fidelity"})
        raise AssertionError("expected SystemExit on duplicate id")
    except SystemExit as e:
        assert e.code == 1

    # Non-finite and boolean scores must fail closed, not silently coerce or
    # let json's non-standard Infinity/NaN literals flip a rubric to pass:true.
    for bad in (
        [{"id": "a", "score": float("inf"), "max": 10, "weight": 3, "insufficient": False},
         {"id": "b", "score": 3, "max": 10, "weight": 2, "insufficient": False}],
        [{"id": "a", "score": float("nan"), "max": 10, "weight": 3, "insufficient": False},
         {"id": "b", "score": 5, "max": 10, "weight": 2, "insufficient": False}],
        [{"id": "a", "score": True, "max": 10, "weight": 3, "insufficient": False},
         {"id": "b", "score": 5, "max": 10, "weight": 2, "insufficient": False}],
    ):
        try:
            score({"scores": bad, "passThreshold": 7.0})
            raise AssertionError(f"expected SystemExit on non-numeric/non-finite input: {bad}")
        except SystemExit as e:
            assert e.code == 1

    # floorPct/passThreshold must fail closed on non-finite/bool input, not
    # silently let a -Infinity threshold or a NaN floor rubber-stamp pass:true
    # (found live: passThreshold=-Infinity made a 1/10 score report pass:true).
    for bad_payload in (
        {"scores": [{"id": "a", "score": 1, "max": 10, "weight": 1, "insufficient": False}],
         "passThreshold": float("-inf")},
        {"scores": [{"id": "a", "score": 2, "max": 10, "weight": 1, "insufficient": False}],
         "floorPct": float("nan")},
        {"scores": [{"id": "a", "score": 1, "max": 10, "weight": 1, "insufficient": False}],
         "passThreshold": True},
        {"scores": [{"id": "a", "score": 1, "max": 10, "weight": 1, "insufficient": False}],
         "floorPct": 1.5},
    ):
        try:
            score(bad_payload)
            raise AssertionError(f"expected SystemExit on bad floorPct/passThreshold: {bad_payload}")
        except SystemExit as e:
            assert e.code == 1

    # A score outside [0, max] must fail closed, not silently inflate the ratio
    # past 1.0 into the total.
    try:
        score({"scores": [{"id": "a", "score": 15, "max": 10, "weight": 1, "insufficient": False}]})
        raise AssertionError("expected SystemExit on score > max")
    except SystemExit as e:
        assert e.code == 1

    # Negative weight must fail closed.
    try:
        score({"scores": [{"id": "a", "score": 5, "max": 10, "weight": -1, "insufficient": False}]})
        raise AssertionError("expected SystemExit on negative weight")
    except SystemExit as e:
        assert e.code == 1

    # primaryId not present among scores must fail closed.
    try:
        score({"scores": [{"id": "a", "score": 5, "max": 10, "weight": 1, "insufficient": False}],
               "primaryId": "nonexistent"})
        raise AssertionError("expected SystemExit on primaryId not found")
    except SystemExit as e:
        assert e.code == 1

    # A malformed score entry (missing a required key) must fail closed.
    try:
        score({"scores": [{"id": "a", "score": 5, "max": 10}]})  # no "weight"
        raise AssertionError("expected SystemExit on malformed score entry")
    except SystemExit as e:
        assert e.code == 1

    # An empty scores list must fail closed, not raise an unguarded exception.
    try:
        score({"scores": []})
        raise AssertionError("expected SystemExit on empty scores list")
    except SystemExit as e:
        assert e.code == 1

    # Floor boundary: a score exactly at floorPct * max must NOT trip
    # belowFloor -- the check is strictly '<', not '<='. Discriminates a
    # future <= regression, which both idea-audit/SKILL.md and the CHANGELOG
    # now state as the documented behavior.
    at_floor = score({"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1,
                                   "insufficient": False}], "floorPct": 0.5})
    assert at_floor["belowFloor"] == [], at_floor

    # --- Weight-sensitivity (`perturb`) fixtures ---

    # Stable pass: research-doc row 2 (7/8/7, weights 3/3.5/3.5).
    row2 = [
        {"id": "ev", "score": 7, "max": 10, "weight": 3, "insufficient": False},
        {"id": "ease", "score": 8, "max": 10, "weight": 3.5, "insufficient": False},
        {"id": "val", "score": 7, "max": 10, "weight": 3.5, "insufficient": False},
    ]
    s2 = score({"scores": row2, "passThreshold": 7.0, "perturb": 0.2})
    assert s2["total"] == 7.35, s2["total"]
    assert s2["sensitivity"]["totalRange"] == [7.26, 7.45], s2["sensitivity"]
    assert s2["sensitivity"]["verdictStable"] is True, s2["sensitivity"]

    # Fragile fail: research-doc row 5 (8/10/3) -- already below threshold,
    # not floor-tripped, and the range straddles it too.
    row5 = [
        {"id": "ev", "score": 8, "max": 10, "weight": 3, "insufficient": False},
        {"id": "ease", "score": 10, "max": 10, "weight": 3.5, "insufficient": False},
        {"id": "val", "score": 3, "max": 10, "weight": 3.5, "insufficient": False},
    ]
    s5 = score({"scores": row5, "passThreshold": 7.0, "perturb": 0.2})
    assert s5["total"] == 6.95, s5["total"]
    assert s5["pass"] is False
    assert s5["sensitivity"]["totalRange"] == [6.36, 7.47], s5["sensitivity"]
    assert s5["sensitivity"]["verdictStable"] is False, s5["sensitivity"]

    # The case the feature exists for: research-doc row 3 (9/5/8) -- a
    # pass:true whose range straddles the threshold. A verdictStable
    # implementation hardcoded to "True whenever pass is True" fails this.
    row3 = [
        {"id": "ev", "score": 9, "max": 10, "weight": 3, "insufficient": False},
        {"id": "ease", "score": 5, "max": 10, "weight": 3.5, "insufficient": False},
        {"id": "val", "score": 8, "max": 10, "weight": 3.5, "insufficient": False},
    ]
    s3 = score({"scores": row3, "floorPct": 0.5, "passThreshold": 7.0, "perturb": 0.2})
    assert s3["total"] == 7.25 and s3["pass"] is True, s3
    assert s3["sensitivity"]["totalRange"] == [6.91, 7.55], s3["sensitivity"]
    assert s3["sensitivity"]["verdictStable"] is False, s3["sensitivity"]

    # Floor-pinned: below_floor must short-circuit verdictStable to True even
    # though the raw range straddles passThreshold -- pass=False can't move.
    floor_pinned = [
        {"id": "ev", "score": 10, "max": 10, "weight": 3, "insufficient": False},
        {"id": "ease", "score": 10, "max": 10, "weight": 3.5, "insufficient": False},
        {"id": "val", "score": 2, "max": 10, "weight": 3.5, "insufficient": False},
    ]
    sf = score({"scores": floor_pinned, "floorPct": 0.5, "passThreshold": 7.0, "perturb": 0.2})
    assert sf["belowFloor"] == ["val"] and sf["pass"] is False
    lo, hi = sf["sensitivity"]["totalRange"]
    assert lo < 7.0 <= hi, sf["sensitivity"]  # the range genuinely straddles the threshold
    assert sf["sensitivity"]["verdictStable"] is True, sf["sensitivity"]

    # An insufficient-flagged axis must be excluded from both perturbation and
    # the axis count -- reuses dims_partial (regression_safety insufficient,
    # 4 scored axes) and must match out2["total"] == 8.0 exactly.
    si = score({"scores": dims_partial, "floorPct": 0.5, "passThreshold": 7.0, "perturb": 0.2})
    assert si["total"] == 8.0 == out2["total"]
    lo, hi = si["sensitivity"]["totalRange"]
    assert lo <= si["total"] <= hi, si["sensitivity"]  # range must bracket its own total

    # perturb out of (0, 1), non-finite, or boolean must all fail closed --
    # including the fail-open this repo's own review found: an unbounded
    # perturb (>=1) can drive a perturbed weight to <=0 and corrupt the ratio
    # silently instead of raising, or divide by zero outright.
    for bad_p in (0, 1, True, 1.5, 2.5, float("nan"), float("inf"), "0.2"):
        try:
            score({"scores": row2, "passThreshold": 7.0, "perturb": bad_p})
            raise AssertionError(f"expected SystemExit on perturb={bad_p!r}")
        except SystemExit as e:
            assert e.code == 1

    # A weight-0 axis must not count toward the perturb axis cap -- it has no
    # effect on the ratio, same as `insufficient`. Found by mh:deep-audit
    # 2026-09-20: 12 weight-0 placeholders + 1 real axis used to fail closed
    # under perturb (13 > MAX_PERTURB_AXES) despite scoring fine without it.
    zero_weight_axes = ([{"id": f"z{i}", "score": 5, "max": 10, "weight": 0,
                           "insufficient": False} for i in range(12)]
                         + [{"id": "eff", "score": 8, "max": 10, "weight": 1,
                             "insufficient": False}])
    zw = score({"scores": zero_weight_axes, "passThreshold": 0.7, "perturb": 0.2})
    assert zw["total"] == 0.8, zw
    assert zw["sensitivity"]["totalRange"] == [0.8, 0.8], zw["sensitivity"]

    # More scored axes than the cap must fail closed, not stall on 2**13 corners.
    many_axes = [{"id": f"a{i}", "score": 5, "max": 10, "weight": 1, "insufficient": False}
                 for i in range(13)]
    try:
        score({"scores": many_axes, "perturb": 0.2})
        raise AssertionError("expected SystemExit on >12 scored axes")
    except SystemExit as e:
        assert e.code == 1

    # Omitting `perturb` must return exactly the original 5 keys -- no
    # regression in the non-opt-in path.
    no_perturb = score({"scores": [{"id": "x", "score": 5, "max": 10, "weight": 1,
                                     "insufficient": False}]})
    assert set(no_perturb.keys()) == {"total", "weightSum", "belowFloor", "pass",
                                       "primaryWeightOk"}, no_perturb

    # 2026-09-21 deep-audit: `insufficient` must be a real bool. A string
    # "false" is truthy, so bool("false") silently dropped the axis -- a 0/10
    # score vanished from belowFloor with no error. Same posture as the
    # bool/numeric guard on score/max/weight: reject, don't coerce.
    for bad_insuff in ("false", "true", 0, 1, None):
        try:
            score({"scores": [{"id": "a", "score": 0, "max": 10, "weight": 1,
                               "insufficient": bad_insuff},
                              {"id": "b", "score": 8, "max": 10, "weight": 1,
                               "insufficient": False}], "floorPct": 0.5})
            raise AssertionError(f"expected SystemExit on insufficient={bad_insuff!r}")
        except SystemExit as e:
            assert e.code == 1
    # Absent `insufficient` still defaults to False (the documented default).
    absent = score({"scores": [{"id": "a", "score": 0, "max": 10, "weight": 1}], "floorPct": 0.5})
    assert absent["belowFloor"] == ["a"], absent

    # A non-object payload (a JSON list) must fail closed with the one-line
    # reason, not escape as an AttributeError traceback.
    try:
        score([{"id": "a", "score": 5, "max": 10, "weight": 1, "insufficient": False}])
        raise AssertionError("expected SystemExit on non-object payload")
    except SystemExit as e:
        assert e.code == 1

    print("weighted-score.py selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        json.dump(score(json.load(sys.stdin)), sys.stdout, indent=2)
        print()
