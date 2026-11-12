#!/usr/bin/env python3
"""Structural self-consistency check for agents/plan-reviewer.md's fatal-weakness-floor gate.

Found by mh:deep-audit 2026-09-19: plan-reviewer is an adversarial surface in this repo with no
schema and no script (requirement-analyst.md has the identical gap and no sibling script of its
own -- confirmed 2026-09-20, not fixed here) -- Critical/High/Medium/Low severity and the resulting verdict are
both model-assigned in prose, with the exact self-contradiction the agent's own Anti-Patterns
list names ("verdict: production-ready alongside a non-empty top_blockers list") caught only if
the same model that made the mistake also happens to notice it.

This does NOT re-review the plan or second-guess a severity assignment -- that's a judgment
call, not this script's job. It only checks that `verdict` and `top_blockers_count` are the
values `findings` mechanically implies, per plan-reviewer.md's own severity rule:
  production-ready: zero findings of any severity
  ready-with-caveats: only Medium/Low findings remain
  needs-revision: at least one Critical or High finding
`not-ready` is deliberately NOT checked against `findings` here -- per plan-reviewer.md, it's a
different question ("can this plan even be evaluated") that needs judgment about whether the
plan names a target at all, not a function of severity counts.

stdin: {"findings": [{"severity": "Critical"|"High"|"Medium"|"Low"}, ...],
        "top_blockers_count": int, "verdict": "production-ready"|"ready-with-caveats"|
        "needs-revision"|"not-ready"}

`findings` here is the FULL list from plan-reviewer's `findings:` field, not the (possibly
truncated) `top_blockers:` display list -- plan-reviewer.md caps `top_blockers` at 10 entries for
readability, but `top_blockers_count` must be the full, uncapped Critical+High tally from
`findings`. Found by mh:deep-audit 2026-09-19: a caller computing `top_blockers_count` from
`len(top_blockers)` on a plan with more than 10 Critical/High findings would get a mechanically
correct review rejected here for a display artifact, not a real inconsistency.

Exit 0: consistent (or `not-ready`, not checked against findings) -- nothing on stdout.
Exit 1: verdict doesn't match what `findings` implies, or `top_blockers_count` doesn't equal
the Critical+High count -- reason on stderr.
"""
import json
import sys

VERDICTS = {"production-ready", "ready-with-caveats", "needs-revision", "not-ready"}
SEVERITIES = {"Critical", "High", "Medium", "Low"}


def expected_verdict(findings):
    severities = [f["severity"] for f in findings]
    if not severities:
        return "production-ready"
    if any(s in ("Critical", "High") for s in severities):
        return "needs-revision"
    return "ready-with-caveats"


def check(obj):
    """Return (ok, reason)."""
    if not isinstance(obj, dict) or set(obj.keys()) != {"findings", "top_blockers_count", "verdict"}:
        return False, f"expected exactly {{findings, top_blockers_count, verdict}}: {obj!r}"
    findings = obj["findings"]
    if not isinstance(findings, list):
        return False, "'findings' is not a list"
    for i, f in enumerate(findings):
        if not isinstance(f, dict) or set(f.keys()) != {"severity"} or f.get("severity") not in SEVERITIES:
            return False, f"findings[{i}] must be exactly {{severity: Critical|High|Medium|Low}}: {f!r}"
    blockers = obj["top_blockers_count"]
    if not isinstance(blockers, int) or isinstance(blockers, bool) or blockers < 0:
        return False, f"'top_blockers_count' must be a non-negative integer: {blockers!r}"
    verdict = obj["verdict"]
    if verdict not in VERDICTS:
        return False, f"'verdict' must be one of {sorted(VERDICTS)}: {verdict!r}"

    critical_high = sum(1 for f in findings if f["severity"] in ("Critical", "High"))
    if blockers != critical_high:
        return False, (f"top_blockers_count is {blockers} but {critical_high} Critical/High "
                        f"finding(s) exist")

    if verdict == "not-ready":
        return True, ""  # judgment call, not checked against findings

    want = expected_verdict(findings)
    if verdict != want:
        return False, f"verdict '{verdict}' but findings imply '{want}'"
    return True, ""


def main():
    obj = json.load(sys.stdin)
    ok, reason = check(obj)
    if not ok:
        print(f"plan-verdict-check: rejected — {reason}", file=sys.stderr)
        return 1
    return 0


def _selftest():
    def run(obj):
        return check(obj)

    # Clean plan: no findings, production-ready, 0 blockers.
    ok, reason = run({"findings": [], "top_blockers_count": 0, "verdict": "production-ready"})
    assert ok, reason

    # Only Medium/Low: ready-with-caveats, 0 blockers.
    ok, reason = run({"findings": [{"severity": "Medium"}, {"severity": "Low"}],
                       "top_blockers_count": 0, "verdict": "ready-with-caveats"})
    assert ok, reason

    # One Critical: needs-revision, 1 blocker.
    ok, reason = run({"findings": [{"severity": "Critical"}], "top_blockers_count": 1,
                       "verdict": "needs-revision"})
    assert ok, reason

    # The exact Anti-Patterns self-contradiction: production-ready with a real blocker.
    ok, reason = run({"findings": [{"severity": "Critical"}], "top_blockers_count": 1,
                       "verdict": "production-ready"})
    assert not ok and "findings imply" in reason, (ok, reason)

    # top_blockers_count that doesn't match the Critical/High count.
    ok, reason = run({"findings": [{"severity": "Critical"}, {"severity": "High"}],
                       "top_blockers_count": 1, "verdict": "needs-revision"})
    assert not ok and "2 Critical/High" in reason, (ok, reason)

    # not-ready is accepted regardless of findings (a judgment call, not checked here).
    ok, reason = run({"findings": [{"severity": "Low"}], "top_blockers_count": 0,
                       "verdict": "not-ready"})
    assert ok, reason

    # not-ready still enforces the top_blockers_count/Critical-High match.
    ok, reason = run({"findings": [{"severity": "Critical"}], "top_blockers_count": 0,
                       "verdict": "not-ready"})
    assert not ok and "1 Critical/High" in reason, (ok, reason)

    # Malformed severity rejected.
    ok, reason = run({"findings": [{"severity": "Blocker"}], "top_blockers_count": 0,
                       "verdict": "production-ready"})
    assert not ok and "severity" in reason, (ok, reason)

    # Extra field rejected.
    ok, reason = run({"findings": [], "top_blockers_count": 0, "verdict": "production-ready",
                       "confidence": 90})
    assert not ok, (ok, reason)

    # top_blockers_count is the FULL Critical+High tally, not the display-capped
    # top_blockers list length -- 11 Critical findings, correctly counted, must
    # pass even though plan-reviewer.md's own template caps the displayed list at 10.
    eleven_criticals = [{"severity": "Critical"} for _ in range(11)]
    ok, reason = run({"findings": eleven_criticals, "top_blockers_count": 11,
                       "verdict": "needs-revision"})
    assert ok, reason

    # The same 11-Critical plan with top_blockers_count taken from the capped
    # display list (10) instead of the full tally must be rejected, not silently
    # accepted as "close enough".
    ok, reason = run({"findings": eleven_criticals, "top_blockers_count": 10,
                       "verdict": "needs-revision"})
    assert not ok and "11 Critical/High" in reason, (ok, reason)

    print("plan-verdict-check.py selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        sys.exit(main())
