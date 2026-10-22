#!/usr/bin/env python3
"""Validate a dispatched validator/checker's verdict on the Claude fallback path.

Used when mh:deep-audit's Codex checker is unavailable and SKILL.md dispatches
a Claude Explore/review agent instead (see SKILL.md step 3, "On any other
outcome"). That agent has no --output-schema enforcement, so this script is
the only shape check its return value gets.

stdin: the dispatched agent's raw final message text.

Behavior:
  - Checked first, unconditionally: a literal `NEEDS-DECISION` (docs/
    reference/spawn-brief.md's escalation return) anywhere OUTSIDE a parsed
    JSON span wins over any JSON found nearby (mask_json_spans masks out
    every substring that parses as JSON first, so a match found only inside
    an otherwise-valid verdict's own string field -- e.g. an `evidence`
    value that legitimately cites this escape hatch by name -- isn't
    mistaken for a real escalation). The contract is either a verdict object OR
    an escalation, never both, so a hedged/hypothetical object quoted ahead
    of a real escalation ("if I could conclude, it'd be {...} but I can't")
    must not be silently accepted as the answer, and unrelated JSON-shaped
    prose after the escalation (an example, a config snippet) must not get
    misclassified as a malformed verdict instead of the escalation it is.
  - Otherwise scans every '{' in the text and keeps whichever parse fully
    validates against the schema below -- narration before the real JSON can
    itself contain a brace, e.g. the agent echoing docs/reference/
    spawn-brief.md's own return-contract line (that fragment isn't valid
    JSON, so it never becomes a candidate).
  - If more than one *distinct* schema-valid object is found in the same
    message (e.g. a fully-formed example verdict quoted in narration ahead of
    the agent's real one), that's ambiguous and rejected rather than silently
    picking the first or last -- a nested findings[] item ({summary,
    evidence}) never counts as a second candidate, since it doesn't carry the
    other required top-level keys.
  - Validates each candidate against the exact contract
    references/checker-output-schema.json states: {contract_version, pass,
    findings[], checked[], scope_ok, unexpected_files[]} and nothing else.
    `contract_version` must equal CONTRACT_VERSION exactly -- a mismatch gets
    its own rejection reason distinct from a generic key-set mismatch, so a
    caller running a stale brief/schema copy fails loud instead of quietly
    passing shape checks it happens to still satisfy. `pass`/`scope_ok` must
    be real booleans; `findings[]` items must be exactly {summary, evidence}
    (both strings); `checked[]` must be non-empty, items exactly {claim,
    evidence} (both strings) -- required even on a clean pass with an empty
    `findings[]`, closing the vacuous-accept case where `pass: true,
    findings: []` is schema-valid but shows no verification work happened
    (found by mh:deep-audit 2026-09-19: a checker primed with 3 known-suspect
    items addressed 0 of them; mirrors mh:idea-audit's identical `checked[]`
    guard). Every `evidence` must carry a citation shape (CITATION_RE: a
    backticked command, or path:line), the same one mh:idea-audit's
    check-citations.py enforces (#392). `unexpected_files[]` must be a list
    of strings.

Exit codes: 0 = exactly one valid verdict (printed to stdout as JSON); 1 =
malformed, rejected, or ambiguous (reason on stderr, nothing on stdout --
never reaches a fixer brief); 2 = NEEDS-DECISION escalation, no verdict
object (the question, if found, on stdout; noted on stderr).
"""
import json
import re
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "scripts", "_lib"))
from verdict_json import CITATION_RE, mask_json_spans, extract_object, extract_valid_candidates  # noqa: E402

CONTRACT_VERSION = 1
REQUIRED_KEYS = {"contract_version", "pass", "findings", "checked", "scope_ok", "unexpected_files"}
FINDING_KEYS = {"summary", "evidence"}
CHECKED_KEYS = {"claim", "evidence"}


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
    if obj["pass"] is None:
        return False, "'pass' is null — the checker's documented can't-tell state, not a valid verdict to act on"
    if not isinstance(obj["pass"], bool):
        return False, f"'pass' is not a boolean: {obj['pass']!r}"
    if not isinstance(obj["scope_ok"], bool):
        return False, f"'scope_ok' is not a boolean: {obj['scope_ok']!r}"
    if not isinstance(obj["findings"], list):
        return False, "'findings' is not a list"
    for idx, f in enumerate(obj["findings"]):
        if not isinstance(f, dict) or set(f.keys()) != FINDING_KEYS:
            return False, f"findings[{idx}] is not exactly {{summary, evidence}}: {f!r}"
        if not isinstance(f.get("summary"), str) or not isinstance(f.get("evidence"), str):
            return False, f"findings[{idx}].summary/evidence must be strings: {f!r}"
        if not f["summary"].strip() or not f["evidence"].strip():
            return False, f"findings[{idx}].summary/evidence must not be blank: {f!r}"
        if not CITATION_RE.search(f["evidence"]):
            return False, (f"findings[{idx}].evidence has no citation shape "
                           f"(backticked command, or path:line): {f!r}")
    if not isinstance(obj["checked"], list):
        return False, "'checked' is not a list"
    if len(obj["checked"]) == 0:
        return False, "'checked' is empty — no verification work shown, even on a clean pass"
    for idx, c in enumerate(obj["checked"]):
        if not isinstance(c, dict) or set(c.keys()) != CHECKED_KEYS:
            return False, f"checked[{idx}] is not exactly {{claim, evidence}}: {c!r}"
        if not isinstance(c.get("claim"), str) or not isinstance(c.get("evidence"), str):
            return False, f"checked[{idx}].claim/evidence must be strings: {c!r}"
        if not c["claim"].strip() or not c["evidence"].strip():
            return False, f"checked[{idx}].claim/evidence must not be blank: {c!r}"
        if not CITATION_RE.search(c["evidence"]):
            return False, (f"checked[{idx}].evidence has no citation shape "
                           f"(backticked command, or path:line): {c!r}")
    if not isinstance(obj["unexpected_files"], list) or not all(
        isinstance(x, str) for x in obj["unexpected_files"]
    ):
        return False, "'unexpected_files' is not a list of strings"
    # A checker can't self-report a clean pass over a run that touched the
    # wrong scope -- scope_ok/unexpected_files are the host's own scope
    # facts, not something the checker's opinion can override. M1's own plan
    # text said "force pass to false"; this rejects the whole object instead
    # (exit 1, triggers SKILL.md's retry-once) -- deliberate, not a
    # deviation: coercing pass in place would silently launder a checker's
    # bad self-report into a different guessed value with no chance to
    # correct itself, the same thing the pass:null handling above (L7)
    # refuses to do. Reject-and-retry matches this file's own established
    # posture everywhere else it distrusts a self-report.
    if obj["pass"] and (not obj["scope_ok"] or obj["unexpected_files"]):
        return False, ("'pass' is true but scope_ok is false or unexpected_files is "
                        "non-empty — an out-of-scope run cannot self-report a clean pass")
    return True, ""


def main():
    text = sys.stdin.read()
    # Checked first, unconditionally: the spawn-brief contract is either a
    # verdict object OR a NEEDS-DECISION escalation, never both. A literal
    # NEEDS-DECISION anywhere OUTSIDE any parsed JSON span means the agent
    # explicitly declined to guess, so it must win over any JSON found nearby
    # -- a hedged/hypothetical verdict quoted ahead of it ("if I could
    # conclude, it'd be {...} but I can't without X") must not be silently
    # accepted as the real answer, and unrelated JSON-shaped prose after it
    # must not get misclassified as a malformed verdict instead of the
    # escalation it is. Masking first (mask_json_spans) means a match found
    # only inside a valid verdict's own string field -- data, not a real
    # escalation -- doesn't win; see that function's docstring.
    match = re.search(r"NEEDS-DECISION\b.*", mask_json_spans(text))
    if match:
        print(match.group(0).strip())
        print("check-verdict: escalation (NEEDS-DECISION), not a malformed verdict", file=sys.stderr)
        return 2
    candidates = extract_valid_candidates(text, validate)
    if len(candidates) == 1:
        json.dump(candidates[0], sys.stdout, indent=2)
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

    checked = [{"claim": "c", "evidence": "skills/foo.py:12"}]
    good = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked,
                        "scope_ok": True, "unexpected_files": []})
    code, out, err = run(good)
    assert code == 0 and json.loads(out) == json.loads(good), (code, out, err)

    extra_field = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked,
                               "scope_ok": True, "unexpected_files": [], "notes": "extra"})
    code, out, err = run(extra_field)
    assert code == 1 and "key set mismatch" in err, (code, out, err)

    # contract_version mismatch gets its own reason, distinct from a generic
    # key-set mismatch -- a stale caller running an old brief/schema copy
    # fails loud and specifically, not silently on some unrelated shape check.
    wrong_version = json.dumps({"contract_version": 2, "pass": True, "findings": [], "checked": checked,
                                 "scope_ok": True, "unexpected_files": []})
    code, out, err = run(wrong_version)
    assert code == 1 and "contract_version" in err and "expected 1" in err, (code, out, err)

    missing_version = json.dumps({"pass": True, "findings": [], "checked": checked,
                                   "scope_ok": True, "unexpected_files": []})
    code, out, err = run(missing_version)
    assert code == 1 and "key set mismatch" in err and "contract_version" in err, (code, out, err)

    pass_as_string = json.dumps({"contract_version": 1, "pass": "mostly", "findings": [], "checked": checked,
                                  "scope_ok": True, "unexpected_files": []})
    code, out, err = run(pass_as_string)
    assert code == 1 and "'pass' is not a boolean" in err, (code, out, err)

    # LOW (harness gap-audit, 2026-09-20): pass:null is the checker's
    # documented can't-tell state, schema-legal now, but must still be
    # rejected -- not silently laundered into a guessed true/false.
    pass_null = json.dumps({"contract_version": 1, "pass": None, "findings": [], "checked": checked,
                             "scope_ok": True, "unexpected_files": []})
    code, out, err = run(pass_null)
    assert code == 1 and "can't-tell state" in err, (code, out, err)

    scope_ok_null = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked,
                                 "scope_ok": None, "unexpected_files": []})
    code, out, err = run(scope_ok_null)
    assert code == 1 and "'scope_ok' is not a boolean" in err, (code, out, err)

    bad_finding = json.dumps({"contract_version": 1, "pass": False,
                               "findings": [{"issue": "x", "sev": "high"}],
                               "checked": checked,
                               "scope_ok": True, "unexpected_files": []})
    code, out, err = run(bad_finding)
    assert code == 1 and "findings[0]" in err, (code, out, err)

    # Vacuous-pass guard: an empty checked[] must be rejected even on an
    # otherwise clean pass:true/findings:[] -- it shows no verification work
    # happened. This is the exact shape a checker primed with known-suspect
    # items and asked to confirm/dispute them produced live: zero findings,
    # nothing addressing the primed items either.
    empty_checked = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": [],
                                 "scope_ok": True, "unexpected_files": []})
    code, out, err = run(empty_checked)
    assert code == 1 and "'checked' is empty" in err, (code, out, err)

    # M1 (harness gap-audit, 2026-09-20): pass:true can't override the host's
    # own scope facts.
    pass_true_scope_bad = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked,
                                       "scope_ok": False, "unexpected_files": []})
    code, out, err = run(pass_true_scope_bad)
    assert code == 1 and "cannot self-report a clean pass" in err, (code, out, err)

    pass_true_unexpected_files = json.dumps({"contract_version": 1, "pass": True, "findings": [],
                                              "checked": checked,
                                              "scope_ok": True, "unexpected_files": ["x.py"]})
    code, out, err = run(pass_true_unexpected_files)
    assert code == 1 and "cannot self-report a clean pass" in err, (code, out, err)

    # pass:false is unaffected -- a legitimate failing run over the wrong
    # scope must still be reportable as a failure, not a schema rejection.
    pass_false_scope_bad = json.dumps({"contract_version": 1, "pass": False, "findings": [], "checked": checked,
                                        "scope_ok": False, "unexpected_files": []})
    code, out, err = run(pass_false_scope_bad)
    assert code == 0, (code, out, err)

    # M6 (harness gap-audit, 2026-09-20): blank summary/evidence/claim strings
    # are schema-valid non-empty-type but carry no content.
    blank_finding = json.dumps({"contract_version": 1, "pass": False,
                                 "findings": [{"summary": "  ", "evidence": "e"}],
                                 "checked": checked, "scope_ok": True, "unexpected_files": []})
    code, out, err = run(blank_finding)
    assert code == 1 and "must not be blank" in err, (code, out, err)

    blank_checked = json.dumps({"contract_version": 1, "pass": True, "findings": [],
                                 "checked": [{"claim": "c", "evidence": ""}],
                                 "scope_ok": True, "unexpected_files": []})
    code, out, err = run(blank_checked)
    assert code == 1 and "must not be blank" in err, (code, out, err)

    # Narration echoing the return contract's own brace before the real JSON.
    echoed = ('Return {contract_version, pass, findings[], checked[], scope_ok, '
              'unexpected_files[]} as instructed.\n' + good)
    code, out, err = run(echoed)
    assert code == 0 and json.loads(out) == json.loads(good), (code, out, err)

    # A findings[]/checked[] item's own braces must not be mistaken for a
    # second candidate -- neither carries the other required top-level keys,
    # so it can never validate on its own.
    with_finding = json.dumps({"contract_version": 1, "pass": False,
                                "findings": [{"summary": "s", "evidence": "ran `git log -1`"}],
                                "checked": checked,
                                "scope_ok": True, "unexpected_files": []})
    code, out, err = run(with_finding)
    assert code == 0 and json.loads(out) == json.loads(with_finding), (code, out, err)

    # #392: evidence must be a citation, not just a non-blank string.
    for where, bad_ev in (("checked", "x"), ("findings", "looks wrong to me"), ("checked", "ratio 2.5:1")):
        obj = json.loads(with_finding)
        obj[where][0]["evidence"] = bad_ev
        code, out, err = run(json.dumps(obj))
        assert code == 1 and "no citation shape" in err, (where, bad_ev, code, out, err)

    # Decoy bypass: a fully schema-valid example quoted in narration ahead of
    # the agent's real, differently-valued verdict must be rejected as
    # ambiguous, not silently accepted as "the first parseable object".
    decoy = json.dumps({"contract_version": 1, "pass": False, "findings": [], "checked": checked,
                         "scope_ok": False, "unexpected_files": []})
    real = json.dumps({"contract_version": 1, "pass": True,
                        "findings": [{"summary": "s", "evidence": "ran `git log -1`"}],
                        "checked": checked,
                        "scope_ok": True, "unexpected_files": []})
    code, out, err = run(f"Example shape: {decoy}\nActual result: {real}")
    assert code == 1 and "ambiguous" in err and out == "", (code, out, err)

    # The same valid object repeated verbatim is not ambiguous -- content is
    # identical, so there is exactly one real candidate to report.
    code, out, err = run(f"{good}\n{good}")
    assert code == 0 and json.loads(out) == json.loads(good), (code, out, err)

    escalation = "I can't determine this safely.\nNEEDS-DECISION does file X own behavior Y?"
    code, out, err = run(escalation)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)
    assert "escalation" in err

    # A hedged/hypothetical verdict quoted ahead of a real escalation must
    # not be silently accepted as the answer -- NEEDS-DECISION wins.
    hedge_then_escalate = (
        f"If I could conclude, the shape I'd return is {decoy} but I can't "
        "commit to that without seeing the file.\n"
        "NEEDS-DECISION does gate X still apply after the file was deleted?"
    )
    code, out, err = run(hedge_then_escalate)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)

    # A genuine escalation must not be misclassified as a malformed verdict
    # just because unrelated JSON-shaped prose (a quoted config snippet)
    # appears in the same message.
    escalation_with_unrelated_json = (
        'the config block looks like {"timeout": 30} in one place and '
        '{"timeout": 60} in another.\n'
        "NEEDS-DECISION which config value is the source of truth here?"
    )
    code, out, err = run(escalation_with_unrelated_json)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)

    # A fully valid verdict whose OWN evidence string legitimately quotes
    # "NEEDS-DECISION" (citing this exact escape hatch by name, plausible in
    # this repo) must be accepted as the verdict, not misclassified as an
    # escalation -- the phrase only appears inside an already-parsed JSON
    # string field, never outside any JSON span.
    verdict_citing_escalation = json.dumps({
        "contract_version": 1,
        "pass": True,
        "findings": [],
        "checked": [{"claim": "verifier-brief.md documents its escape hatch",
                      "evidence": "verifier-brief.md:44 tells the verifier to return "
                                  "NEEDS-DECISION <question> instead of guessing"}],
        "scope_ok": True, "unexpected_files": [],
    })
    code, out, err = run(verdict_citing_escalation)
    assert code == 0 and json.loads(out) == json.loads(verdict_citing_escalation), (code, out, err)

    # Same case, but a REAL escalation also appears outside any JSON span in
    # the same message -- the real escalation must still win even though the
    # text also contains a valid-looking verdict citing the phrase in prose.
    cited_then_real_escalation = (
        f"{verdict_citing_escalation}\n"
        "On second thought I can't safely conclude this.\n"
        "NEEDS-DECISION does the cited line still apply after the file moved?"
    )
    code, out, err = run(cited_then_real_escalation)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)

    print("check-verdict.py selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        sys.exit(main())
