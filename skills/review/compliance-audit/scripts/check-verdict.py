#!/usr/bin/env python3
"""Validate a dispatched compliance-audit verifier's return value and compute `pass`.

Mirrors mh:deep-audit's scripts/check-verdict.py (same NEEDS-DECISION escape hatch,
same brace-scanning, same ambiguity handling) for compliance-audit's own contract:
references/verifier-output-schema.json. Used on both paths — pipe Codex's
--output-last-message file through this too, not just the Claude-fallback path,
because Codex's --output-schema only guarantees the verifier's JSON matches the
schema; it does not compute `pass`. This script is the only place `pass` is ever
computed: SKILL.md's own rule ("`pass` is never true on requirements alone") is
transcribed here so no hand-eyeballed reconciliation ever reaches the report.

stdin: the verifier's raw final message text (Codex --output-last-message file
contents, or the Claude-fallback agent's final message).

Behavior:
  - A literal `NEEDS-DECISION` anywhere OUTSIDE a parsed JSON span wins over any
    JSON found nearby, same rule as deep-audit's script and for the same reason:
    the contract is a verdict object OR an escalation, never both. mask_json_spans
    masks out JSON first so a match found only inside an otherwise-valid verdict's
    own `note` field isn't mistaken for a real escalation.
  - Scans every '{' in the text and keeps every candidate that fully validates
    against the schema (exact key-set equality) AND the semantic rule below.
    Exactly one valid candidate is required; two or more distinct ones reject as
    ambiguous. `contract_version` must equal CONTRACT_VERSION exactly -- a
    mismatch gets its own rejection reason distinct from a generic key-set
    mismatch, so a stale brief/schema copy fails loud instead of quietly
    passing shape checks it happens to still satisfy.
  - `requirements` must be non-empty. An empty list plus a trivially-clean
    gauntlet (e.g. `exit_code: 0` on an empty `command`) would otherwise satisfy
    `compute_pass`'s `all()` vacuously — found by deep-audit 2026-09-19, the
    same vacuous-pass shape idea-audit's `checked[]` already guards against.
  - Semantic rule beyond the JSON Schema: `accepted` must be a bool when
    `verdict == "DEVIATED"` (was it sanctioned or not — null is not an answer for
    a requirement that actually deviated) and must be null otherwise (CONFORMS/
    MISSING don't have an acceptance question to answer).
  - Computes `pass` per SKILL.md Core Principles: every requirement is CONFORMS or
    an accepted DEVIATED, AND gauntlet.exit_code == 0, AND scope_ok is true, AND
    unexpected_files is empty. A
    verifier-supplied `pass` field is never read — this script is the only
    arithmetic, same reason weighted-score.py is the only place a score total is
    computed.

Exit codes: 0 = exactly one valid verdict (printed to stdout as JSON, with `pass`
added); 1 = malformed, rejected, or ambiguous (reason on stderr, nothing on
stdout — never reaches Phase 3's report); 2 = NEEDS-DECISION escalation.
"""
import json
import re
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "scripts", "_lib"))
from verdict_json import CITATION_RE, mask_json_spans, extract_object, extract_valid_candidates  # noqa: E402

CONTRACT_VERSION = 1
REQUIRED_KEYS = {"contract_version", "requirements", "gauntlet", "scope_ok", "unexpected_files"}
REQUIREMENT_KEYS = {"id", "verdict", "note", "accepted"}
GAUNTLET_KEYS = {"command", "sha", "exit_code", "output_tail"}
VERDICTS = {"CONFORMS", "DEVIATED", "MISSING", "UNVERIFIABLE"}
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")


def validate(obj):
    """Return (ok, reason). reason names what was rejected when not ok."""
    if not isinstance(obj, dict):
        return False, "top-level value is not an object"
    if set(obj.keys()) != REQUIRED_KEYS:
        extra = set(obj.keys()) - REQUIRED_KEYS
        missing = REQUIRED_KEYS - set(obj.keys())
        return False, f"key set mismatch: extra={sorted(extra)} missing={sorted(missing)}"
    if not isinstance(obj["contract_version"], int) or isinstance(obj["contract_version"], bool) \
            or obj["contract_version"] != CONTRACT_VERSION:
        return False, (f"'contract_version' is {obj['contract_version']!r}, expected "
                        f"{CONTRACT_VERSION} -- schema/script/brief may have drifted apart")

    reqs = obj["requirements"]
    if not isinstance(reqs, list):
        return False, "'requirements' is not a list"
    if len(reqs) == 0:
        return False, "'requirements' is empty — no requirement was actually checked"
    for idx, r in enumerate(reqs):
        if not isinstance(r, dict) or set(r.keys()) != REQUIREMENT_KEYS:
            return False, f"requirements[{idx}] is not exactly {{id, verdict, note, accepted}}: {r!r}"
        if not isinstance(r.get("id"), str) or not isinstance(r.get("note"), str):
            return False, f"requirements[{idx}].id/note must be strings: {r!r}"
        if r.get("verdict") not in VERDICTS:
            return False, f"requirements[{idx}].verdict must be one of {sorted(VERDICTS)}: {r!r}"
        accepted = r.get("accepted")
        if r["verdict"] == "DEVIATED":
            if not isinstance(accepted, bool):
                return False, f"requirements[{idx}] is DEVIATED but 'accepted' is not a boolean: {r!r}"
            # M3 (harness gap-audit, 2026-09-20): a sanctioned deviation needs
            # real evidence it was actually checked, not just asserted --
            # same citation shape idea-audit's check-citations.py enforces.
            if accepted is True and not CITATION_RE.search(r["note"]):
                return False, (f"requirements[{idx}] is DEVIATED and accepted but 'note' has no "
                                f"citation shape (backticked command, or path:line): {r!r}")
        elif accepted is not None:
            return False, f"requirements[{idx}] is {r['verdict']} but 'accepted' is not null: {r!r}"

    gauntlet = obj["gauntlet"]
    if not isinstance(gauntlet, dict) or set(gauntlet.keys()) != GAUNTLET_KEYS:
        return False, f"'gauntlet' is not exactly {{command, sha, exit_code, output_tail}}: {gauntlet!r}"
    if not isinstance(gauntlet.get("command"), str) or not isinstance(gauntlet.get("sha"), str) \
            or not isinstance(gauntlet.get("output_tail"), str):
        return False, f"gauntlet.command/sha/output_tail must be strings: {gauntlet!r}"
    if not gauntlet["command"].strip() or not gauntlet["output_tail"].strip():
        return False, f"gauntlet.command/output_tail must not be blank: {gauntlet!r}"
    if not SHA_RE.match(gauntlet["sha"]):
        return False, f"gauntlet.sha is not a 7-40 char lowercase hex commit SHA: {gauntlet['sha']!r}"
    if not isinstance(gauntlet.get("exit_code"), int) or isinstance(gauntlet.get("exit_code"), bool):
        return False, f"gauntlet.exit_code must be an integer: {gauntlet!r}"

    if not isinstance(obj["scope_ok"], bool):
        return False, f"'scope_ok' is not a boolean: {obj['scope_ok']!r}"
    if not isinstance(obj["unexpected_files"], list) or not all(
        isinstance(x, str) for x in obj["unexpected_files"]
    ):
        return False, "'unexpected_files' is not a list of strings"

    return True, ""


def compute_pass(obj):
    """SKILL.md Core Principles, transcribed: pass requires every requirement
    CONFORMS or accepted-DEVIATED, AND the gauntlet exits 0, AND scope_ok,
    AND no unexpected_files. The last clause mirrors deep-audit's sibling
    (its validate() rejects a self-reported pass over a non-empty
    unexpected_files); this verifier never supplies `pass`, so there is no
    self-report to reject -- it is simply computed false. Found by
    mh:deep-audit 2026-09-21: scope_ok:true + ["stray.py"] passed."""
    reqs_ok = all(
        r["verdict"] == "CONFORMS" or (r["verdict"] == "DEVIATED" and r["accepted"] is True)
        for r in obj["requirements"]
    )
    return bool(reqs_ok and obj["gauntlet"]["exit_code"] == 0 and obj["scope_ok"]
                and not obj["unexpected_files"])


def sha_matches(reported, expected):
    """Both sides are 7-40 hex chars per SHA_RE, so the same commit can be
    reported at different lengths; one being a prefix of the other is a
    match. A pin under 7 chars never matches (SHA_RE rejects it) -- "abc"
    would otherwise prefix-match anything."""
    if not SHA_RE.match(expected):
        return False
    return reported.startswith(expected) or expected.startswith(reported)


def main():
    # M5 (harness gap-audit, 2026-09-20): the pinned SHA the orchestrating
    # skill generated for the detached worktree (compliance-audit/SKILL.md
    # Phase 1.4) is the only source of truth -- this script never derives
    # one itself (it runs on the host tree, not inside the pinned worktree,
    # so a `git rev-parse HEAD` here would be the wrong ref). Optional
    # positional arg, not required, so existing callers/tests without a
    # pinned SHA to check against keep working unchanged.
    args = [a for a in sys.argv[1:] if a != "--selftest"]
    expected_sha = args[0] if args else None

    text = sys.stdin.read()
    match = re.search(r"NEEDS-DECISION\b.*", mask_json_spans(text))
    if match:
        print(match.group(0).strip())
        print("check-verdict: escalation (NEEDS-DECISION), not a malformed verdict", file=sys.stderr)
        return 2
    candidates = extract_valid_candidates(text, validate)
    if len(candidates) == 1:
        result = dict(candidates[0])
        if expected_sha is not None and not sha_matches(result["gauntlet"]["sha"], expected_sha):
            print(f"check-verdict: rejected — gauntlet.sha {result['gauntlet']['sha']!r} does not "
                  f"match the pinned SHA {expected_sha!r} the orchestrating skill generated",
                  file=sys.stderr)
            return 1
        result["pass"] = compute_pass(result)
        json.dump(result, sys.stdout, indent=2)
        print()
        return 0
    if len(candidates) > 1:
        print(f"check-verdict: rejected — {len(candidates)} distinct schema-valid "
              "verdict objects found in the same message; ambiguous, refusing to guess",
              file=sys.stderr)
        return 1
    obj = extract_object(text)
    if obj is not None:
        _, reason = validate(obj)
        print(f"check-verdict: rejected — {reason}", file=sys.stderr)
        return 1
    print("check-verdict: rejected — no parseable JSON object and no NEEDS-DECISION found", file=sys.stderr)
    return 1


def _selftest():
    import io
    import contextlib

    def run(text):
        buf_out, buf_err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            old_stdin = sys.stdin
            sys.stdin = io.StringIO(text)
            try:
                code = main()
            finally:
                sys.stdin = old_stdin
        return code, buf_out.getvalue(), buf_err.getvalue()

    good = json.dumps({
        "contract_version": 1,
        "requirements": [
            {"id": "R1", "verdict": "CONFORMS", "note": "", "accepted": None},
            {"id": "R2", "verdict": "DEVIATED", "note": "renamed field, see `git diff HEAD~1 -- foo.py`",
             "accepted": True},
        ],
        "gauntlet": {"command": "bash gauntlet.sh", "sha": "abc1234", "exit_code": 0, "output_tail": "ok"},
        "scope_ok": True,
        "unexpected_files": [],
    })
    code, out, err = run(good)
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is True, (code, out, err)

    unaccepted = json.loads(good)
    unaccepted["requirements"][1]["accepted"] = False
    code, out, err = run(json.dumps(unaccepted))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    missing_req = json.loads(good)
    missing_req["requirements"].append({"id": "R3", "verdict": "MISSING", "note": "", "accepted": None})
    code, out, err = run(json.dumps(missing_req))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    bad_gauntlet = json.loads(good)
    bad_gauntlet["gauntlet"]["exit_code"] = 1
    code, out, err = run(json.dumps(bad_gauntlet))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    scope_bad = json.loads(good)
    scope_bad["scope_ok"] = False
    code, out, err = run(json.dumps(scope_bad))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    # Semantic rule: DEVIATED requires a real boolean 'accepted', not null.
    deviated_null = json.loads(good)
    deviated_null["requirements"][1]["accepted"] = None
    code, out, err = run(json.dumps(deviated_null))
    assert code == 1 and "accepted" in err, (code, out, err)

    # Semantic rule: CONFORMS/MISSING must have 'accepted' null, not a stray bool.
    conforms_bool = json.loads(good)
    conforms_bool["requirements"][0]["accepted"] = True
    code, out, err = run(json.dumps(conforms_bool))
    assert code == 1 and "accepted" in err, (code, out, err)

    extra_field = json.loads(good)
    extra_field["notes"] = "extra"
    code, out, err = run(json.dumps(extra_field))
    assert code == 1 and "key set mismatch" in err, (code, out, err)

    # contract_version mismatch gets its own reason, distinct from a generic
    # key-set mismatch -- a stale caller running an old brief/schema copy
    # fails loud and specifically, not silently on some unrelated shape check.
    wrong_version = json.loads(good)
    wrong_version["contract_version"] = 2
    code, out, err = run(json.dumps(wrong_version))
    assert code == 1 and "contract_version" in err and "expected 1" in err, (code, out, err)

    missing_version = json.loads(good)
    del missing_version["contract_version"]
    code, out, err = run(json.dumps(missing_version))
    assert code == 1 and "key set mismatch" in err and "contract_version" in err, (code, out, err)

    bad_verdict = json.loads(good)
    bad_verdict["requirements"][0]["verdict"] = "PARTIAL"
    code, out, err = run(json.dumps(bad_verdict))
    assert code == 1 and "verdict must be one of" in err, (code, out, err)

    escalation = "I can't determine this safely.\nNEEDS-DECISION is the plan's SHA still resolvable?"
    code, out, err = run(escalation)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)

    # Vacuous pass: empty requirements + trivially-clean gauntlet must be rejected,
    # not silently accepted as pass:true (Python's all([]) is True).
    vacuous = json.loads(good)
    vacuous["requirements"] = []
    code, out, err = run(json.dumps(vacuous))
    assert code == 1 and "empty" in err and out == "", (code, out, err)

    # Decoy ahead of the real, differently-valued verdict must be rejected as ambiguous.
    decoy = json.loads(good)
    decoy["scope_ok"] = False
    code, out, err = run(f"Example shape: {json.dumps(decoy)}\nActual result: {good}")
    assert code == 1 and "ambiguous" in err and out == "", (code, out, err)

    # A fully valid verdict whose OWN `note` field legitimately quotes
    # "NEEDS-DECISION" (citing this exact escape hatch by name) must be
    # accepted as the verdict, not misclassified as an escalation.
    citing = json.loads(good)
    citing["requirements"][0]["note"] = ("verifier-brief.md says return "
                                          "NEEDS-DECISION <question> instead of guessing")
    code, out, err = run(json.dumps(citing))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is True, (code, out, err)

    # M3 (harness gap-audit, 2026-09-20): an accepted deviation needs a real
    # citation in its note, not just an assertion that it was fine.
    accepted_no_citation = json.loads(good)
    accepted_no_citation["requirements"][1]["note"] = "renamed field, looked fine to me"
    code, out, err = run(json.dumps(accepted_no_citation))
    assert code == 1 and "no citation shape" in err, (code, out, err)

    # M3 follow-up (compliance-audit self-check, 2026-09-20): a bare numeric
    # ratio like "2.5:1" must NOT count as a citation -- this regex drifted
    # stale from idea-audit's check-citations.py once before (missing the
    # letter-requiring lookahead); this case pins it so a re-drift fails loud.
    accepted_numeric_ratio = json.loads(good)
    accepted_numeric_ratio["requirements"][1]["note"] = "193x faster, 2.5:1 ratio"
    code, out, err = run(json.dumps(accepted_numeric_ratio))
    assert code == 1 and "no citation shape" in err, (code, out, err)

    # M4: UNVERIFIABLE is a real verdict value and never passes on its own,
    # same as MISSING.
    unverifiable = json.loads(good)
    unverifiable["requirements"].append({"id": "R3", "verdict": "UNVERIFIABLE", "note": "", "accepted": None})
    code, out, err = run(json.dumps(unverifiable))
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    # UNVERIFIABLE with a stray non-null accepted is rejected, same as CONFORMS/MISSING.
    unverifiable_bool = json.loads(good)
    unverifiable_bool["requirements"].append({"id": "R3", "verdict": "UNVERIFIABLE", "note": "", "accepted": True})
    code, out, err = run(json.dumps(unverifiable_bool))
    assert code == 1 and "accepted" in err, (code, out, err)

    # M5: gauntlet.sha must be a real commit SHA shape, not an arbitrary string.
    bad_sha = json.loads(good)
    bad_sha["gauntlet"]["sha"] = "not-a-sha"
    code, out, err = run(json.dumps(bad_sha))
    assert code == 1 and "commit SHA" in err, (code, out, err)

    # M5: blank gauntlet.command/output_tail are schema-valid non-empty-type
    # but carry no content.
    blank_command = json.loads(good)
    blank_command["gauntlet"]["command"] = "   "
    code, out, err = run(json.dumps(blank_command))
    assert code == 1 and "must not be blank" in err, (code, out, err)

    # M5: the orchestrating skill's pinned SHA is the source of truth -- a
    # verifier reporting a different SHA (stale worktree, wrong checkout) is
    # rejected even though its own object is otherwise schema-valid.
    def run_with_argv(text, argv_tail):
        buf_out, buf_err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            old_stdin, old_argv = sys.stdin, sys.argv
            sys.stdin = io.StringIO(text)
            sys.argv = ["check-verdict.py"] + argv_tail
            try:
                code = main()
            finally:
                sys.stdin, sys.argv = old_stdin, old_argv
        return code, buf_out.getvalue(), buf_err.getvalue()

    code, out, err = run_with_argv(good, ["deadbeef0"])
    assert code == 1 and "does not match the pinned SHA" in err, (code, out, err)

    code, out, err = run_with_argv(good, ["abc1234"])
    assert code == 0 and json.loads(out)["pass"] is True, (code, out, err)

    # 2026-09-21 deep-audit: the schema allows 7-40 hex chars on both sides,
    # so a full 40-char pin vs a short report (or vice versa) is the same
    # commit, not a mismatch -- accept when one is a prefix of the other.
    full = "abc1234" + "0" * 33
    code, out, err = run_with_argv(good, [full])
    assert code == 0 and json.loads(out)["pass"] is True, (code, out, err)
    good_full = json.loads(good)
    good_full["gauntlet"]["sha"] = full
    code, out, err = run_with_argv(json.dumps(good_full), ["abc1234"])
    assert code == 0 and json.loads(out)["pass"] is True, (code, out, err)
    # A real mismatch still rejects, and a pin shorter than 7 hex chars is
    # rejected outright -- otherwise "abc" would prefix-match anything.
    code, out, err = run_with_argv(good, ["abc1234" + "f" * 33])
    assert code == 0, (code, out, err)  # same 7-char prefix, still a prefix match
    code, out, err = run_with_argv(json.dumps(good_full), ["abc1234" + "f" * 33])
    assert code == 1 and "does not match the pinned SHA" in err, (code, out, err)
    for short_pin in ("abc", "abc123", "ABC1234", "not-a-sha"):
        code, out, err = run_with_argv(good, [short_pin])
        assert code == 1 and "pinned SHA" in err, (short_pin, code, out, err)

    # 2026-09-21 deep-audit: `unexpected_files` non-empty means the diff
    # touched something the plan never named -- an out-of-scope run cannot
    # pass, same rule deep-audit's sibling applies. compliance-audit's
    # verifier never supplies its own `pass`, so there is no self-report to
    # reject; `pass` is simply computed false.
    stray = json.loads(good)
    stray["unexpected_files"] = ["stray.py"]
    code, out, err = run_with_argv(json.dumps(stray), [])
    parsed = json.loads(out)
    assert code == 0 and parsed["pass"] is False, (code, out, err)

    print("check-verdict.py (compliance-audit) selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        sys.exit(main())
