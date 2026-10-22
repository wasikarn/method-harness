#!/usr/bin/env python3
"""Deterministic ranker for mh:ideate Phase 2.

stdin:  {"scores": {"<ideaId>": {"novelty": 0-10, "viability": 0-10, "fit": 0-10,
                                  "trap": null | "<reason>"}, ...}, "topK": 3}
stdout: {"totals": {id: float}, "shortlist": [id...], "runnerUp": id | null,
         "nonObviousPick": id | null, "traps": [id...]}

The model scores and writes reasons; this script does the arithmetic (weighted
total, ordering, top-K, runner-up, non-obvious pick) so a wrong hand sum can
never reach the output. Run with --selftest to check it.
"""
import json
import math
import sys

W = (0.35, 0.40, 0.25)  # novelty, viability, fit; viability heaviest by design


def _die(reason):
    print(f"rank.py: {reason}", file=sys.stderr)
    sys.exit(1)


def _validated(item_id, s):
    # 2026-09-20 audit: this script's own docstring claims to mirror
    # scripts/_lib/weighted-score.py's contract ("this script does the
    # arithmetic... so a wrong hand sum can never reach the output") -- that
    # file was hardened against exactly this input class, this one wasn't.
    # A bool is silently 0/1 in arithmetic (True * 0.35 == 0.35), and
    # Python's json module accepts the non-standard NaN/Infinity/-Infinity
    # literals by default -- either would silently corrupt totals/ordering
    # with no error (nan comparisons are always False, so sorted()/max()
    # never raise on one).
    for k in ("novelty", "viability", "fit"):
        v = s.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            _die(f"'{item_id}'.{k} must be numeric, not bool: {v!r}")
        if isinstance(v, float) and not math.isfinite(v):
            _die(f"'{item_id}'.{k} must be finite: {v!r}")
        if not (0 <= v <= 10):
            _die(f"'{item_id}'.{k} must be in [0,10]: {v!r}")
    # deep-audit follow-up (2026-09-20): the docstring above and SKILL.md/
    # references/algorithm-detail.md all document trap as null-or-a-reason,
    # never "". M13's `is not None` fix (below, in rank()) legalized trap:""
    # as "a real trap with no reason" -- reject it here instead, matching
    # this repo's own \S non-blank convention for comparable free-text
    # fields (checker-output-schema.json's findings/checked items).
    trap = s.get("trap")
    if trap is not None and (not isinstance(trap, str) or not trap.strip()):
        _die(f"'{item_id}'.trap must be null or a non-blank reason string: {trap!r}")
    return s


def _no_dup(pairs):
    # json keeps the last of two equal keys silently; a repeated idea ID would drop a score.
    keys = [k for k, _ in pairs]
    dup = sorted({k for k in keys if keys.count(k) > 1})
    if dup:
        _die(f"duplicate key(s): {dup}")
    return dict(pairs)


def rank(payload):
    if not isinstance(payload, dict):
        _die(f"payload must be an object, not {type(payload).__name__}")
    scores = payload.get("scores")
    if not isinstance(scores, dict) or not all(isinstance(s, dict) for s in scores.values()):
        _die("'scores' must be an object of per-idea objects")
    for i, s in scores.items():
        _validated(i, s)
    # 2026-09-21 deep-audit: same fail-closed class as _validated() -- int()
    # coerced -1 (rc 0, ranked[:-1]), 0 (empty shortlist) and null (TypeError).
    top_k = payload.get("topK", 3)
    if isinstance(top_k, bool) or not isinstance(top_k, int) or top_k < 1:
        _die(f"'topK' must be an integer >= 1, not bool: {top_k!r}")
    totals = {
        i: round(s["novelty"] * W[0] + s["viability"] * W[1] + s["fit"] * W[2], 2)
        for i, s in scores.items()
    }
    # M13 (harness gap-audit, 2026-09-20): `is not None`, not truthiness -- an
    # empty-string trap reason ("") is still a real trap flag from the model,
    # not "no trap", and truthiness silently dropped it.
    traps = [i for i, s in scores.items() if s.get("trap") is not None]
    ranked = sorted((i for i in scores if i not in traps),
                    key=lambda i: (-totals[i], i))
    shortlist = ranked[:top_k]
    runner_up = ranked[top_k] if len(ranked) > top_k else None
    pick = max(shortlist, key=lambda i: (scores[i]["novelty"] + scores[i]["viability"] * 0.5, -ranked.index(i))) if shortlist else None
    return {"totals": totals, "shortlist": shortlist, "runnerUp": runner_up,
            "nonObviousPick": pick, "traps": traps}


def _selftest():
    out = rank({"topK": 2, "scores": {
        "a": {"novelty": 7, "viability": 6, "fit": 8, "trap": None},
        "b": {"novelty": 9, "viability": 9, "fit": 9, "trap": "false economy"},
        "c": {"novelty": 3, "viability": 9, "fit": 9, "trap": None},
        "d": {"novelty": 8, "viability": 5, "fit": 5, "trap": None},
    }})
    assert out["totals"]["a"] == 6.85, out["totals"]
    assert out["traps"] == ["b"]
    assert out["shortlist"] == ["c", "a"], out["shortlist"]  # c=7.9, a=6.85, d=6.05
    assert out["runnerUp"] == "d"
    assert out["nonObviousPick"] == "a"  # a: 7+3=10 beats c: 3+4.5=7.5
    assert rank({"scores": {}})["runnerUp"] is None

    # Non-finite and boolean scores must fail closed, not silently corrupt
    # the ranking (2026-09-20 audit).
    for bad in (
        {"a": {"novelty": True, "viability": 8, "fit": 7, "trap": None}},
        {"a": {"novelty": float("nan"), "viability": 8, "fit": 7, "trap": None}},
        {"a": {"novelty": float("inf"), "viability": 8, "fit": 7, "trap": None}},
        {"a": {"novelty": "7", "viability": 8, "fit": 7, "trap": None}},
    ):
        try:
            rank({"scores": bad})
            raise AssertionError(f"expected rank() to reject {bad!r}")
        except SystemExit as e:
            assert e.code == 1

    # M13 (harness gap-audit, 2026-09-20): out-of-range scores must fail
    # closed too, same class as the non-finite/boolean cases above -- the
    # docstring's own 0-10 contract was previously unenforced.
    for bad_range in (
        {"a": {"novelty": 15, "viability": 8, "fit": 7, "trap": None}},
        {"a": {"novelty": 5, "viability": -1, "fit": 7, "trap": None}},
    ):
        try:
            rank({"scores": bad_range})
            raise AssertionError(f"expected rank() to reject out-of-range {bad_range!r}")
        except SystemExit as e:
            assert e.code == 1

    # deep-audit follow-up (2026-09-20): trap:"" is neither documented
    # null-trap nor a real reason -- must fail closed, not silently become
    # "a trap with no reason" (the gap M13's own `is not None` fix left open).
    for bad_trap in (
        {"a": {"novelty": 7, "viability": 6, "fit": 8, "trap": ""}},
        {"a": {"novelty": 7, "viability": 6, "fit": 8, "trap": "   "}},
        {"a": {"novelty": 7, "viability": 6, "fit": 8, "trap": 5}},
    ):
        try:
            rank({"scores": bad_trap})
            raise AssertionError(f"expected rank() to reject blank/non-string trap {bad_trap!r}")
        except SystemExit as e:
            assert e.code == 1

    # A genuine non-blank trap reason must still count toward traps[] and be
    # excluded from ranking (already exercised above via "false economy", but
    # asserted explicitly here alongside the rejection cases for locality).
    out = rank({"topK": 2, "scores": {
        "a": {"novelty": 7, "viability": 6, "fit": 8, "trap": None},
        "b": {"novelty": 9, "viability": 9, "fit": 9, "trap": "false economy"},
    }})
    assert out["traps"] == ["b"], out["traps"]
    assert out["shortlist"] == ["a"], out["shortlist"]

    # 2026-09-21 deep-audit: topK must be an integer >= 1 (not a bool). -1
    # returned rc 0 with a nonsense shortlist (ranked[:-1]), 0 an empty one,
    # and null a TypeError -- same input class the score guards above reject.
    ok_scores = {"a": {"novelty": 7, "viability": 6, "fit": 8, "trap": None}}
    for bad_k in (-1, 0, None, True, 2.0, "2"):
        try:
            rank({"topK": bad_k, "scores": ok_scores})
            raise AssertionError(f"expected rank() to reject topK={bad_k!r}")
        except SystemExit as e:
            assert e.code == 1
    assert rank({"scores": ok_scores})["shortlist"] == ["a"]  # absent topK still defaults to 3

    print("rank.py selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        json.dump(rank(json.load(sys.stdin, object_pairs_hook=_no_dup)), sys.stdout, indent=2)
        print()
