#!/usr/bin/env python3
"""Validate a dispatched attacker/fallback's verdict on the Claude fallback path.

Added 2026-09-20 (harness gap-audit M2) — mirrors mh:deep-audit's
scripts/check-verdict.py (same NEEDS-DECISION escape hatch, same
brace-scanning, same ambiguity handling), adapted to idea-audit's own
contract: references/attacker-output-schema.json's {contract_version, pass,
findings[], checked[]} shape has no scope_ok/unexpected_files (idea-audit's
attacker never touches the repo, so there is no scope to report on). Not a
copy of deep-audit's script verbatim -- that script's REQUIRED_KEYS include
two keys this schema doesn't have and would reject every real object outright.

Used on both paths: pipe Codex's --output-last-message file through this
too, not just the Claude-fallback path, since --output-schema only
guarantees shape, not that findings/checked carry a real citation (that is
scripts/check-citations.py's separate job, run after this one passes).

stdin: the attacker's raw final message text (Codex --output-last-message
file contents, or the Claude-fallback agent's final message).

Behavior: identical to deep-audit's check-verdict.py -- NEEDS-DECISION
outside any JSON span wins over nearby JSON; every '{' in the text is a
scan start; exactly one schema-valid candidate is required, two or more
distinct ones reject as ambiguous; `contract_version` must equal
CONTRACT_VERSION exactly, its own rejection reason distinct from a generic
key-set mismatch; findings[]/checked[] items must be exactly {summary,
evidence}/{claim, evidence}, both non-blank strings; checked[] must be
non-empty even on a clean pass (the vacuous-pass guard SKILL.md's Phase 2
already describes in prose, made mechanical here).

Exit codes: 0 = exactly one valid verdict (printed to stdout as JSON); 1 =
malformed, rejected, or ambiguous (reason on stderr, nothing on stdout); 2 =
NEEDS-DECISION escalation, no verdict object (the question, if found, on
stdout; noted on stderr).
"""
import json
import re
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "scripts", "_lib"))
from verdict_json import mask_json_spans, extract_object, extract_valid_candidates  # noqa: E402

CONTRACT_VERSION = 1
REQUIRED_KEYS = {"contract_version", "pass", "findings", "checked"}
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
        return False, "'pass' is null — the attacker's documented can't-tell state, not a valid verdict to act on"
    if not isinstance(obj["pass"], bool):
        return False, f"'pass' is not a boolean: {obj['pass']!r}"
    if not isinstance(obj["findings"], list):
        return False, "'findings' is not a list"
    for idx, f in enumerate(obj["findings"]):
        if not isinstance(f, dict) or set(f.keys()) != FINDING_KEYS:
            return False, f"findings[{idx}] is not exactly {{summary, evidence}}: {f!r}"
        if not isinstance(f.get("summary"), str) or not isinstance(f.get("evidence"), str):
            return False, f"findings[{idx}].summary/evidence must be strings: {f!r}"
        if not f["summary"].strip() or not f["evidence"].strip():
            return False, f"findings[{idx}].summary/evidence must not be blank: {f!r}"
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
    return True, ""


def main():
    text = sys.stdin.read()
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

    checked = [{"claim": "c", "evidence": "e"}]
    good = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked})
    code, out, err = run(good)
    assert code == 0 and json.loads(out) == json.loads(good), (code, out, err)

    extra_field = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": checked,
                               "scope_ok": True})
    code, out, err = run(extra_field)
    assert code == 1 and "key set mismatch" in err, (code, out, err)

    # contract_version mismatch gets its own reason, distinct from a generic
    # key-set mismatch -- a stale caller running an old brief/schema copy
    # fails loud and specifically, not silently on some unrelated shape check.
    wrong_version = json.dumps({"contract_version": 2, "pass": True, "findings": [], "checked": checked})
    code, out, err = run(wrong_version)
    assert code == 1 and "contract_version" in err and "expected 1" in err, (code, out, err)

    missing_version = json.dumps({"pass": True, "findings": [], "checked": checked})
    code, out, err = run(missing_version)
    assert code == 1 and "key set mismatch" in err and "contract_version" in err, (code, out, err)

    pass_as_string = json.dumps({"contract_version": 1, "pass": "mostly", "findings": [], "checked": checked})
    code, out, err = run(pass_as_string)
    assert code == 1 and "'pass' is not a boolean" in err, (code, out, err)

    # LOW (harness gap-audit, 2026-09-20): pass:null is the attacker's
    # documented can't-tell state, schema-legal now, but must still be
    # rejected -- not silently laundered into a guessed true/false.
    pass_null = json.dumps({"contract_version": 1, "pass": None, "findings": [], "checked": checked})
    code, out, err = run(pass_null)
    assert code == 1 and "can't-tell state" in err, (code, out, err)

    bad_finding = json.dumps({"contract_version": 1, "pass": False,
                               "findings": [{"issue": "x"}], "checked": checked})
    code, out, err = run(bad_finding)
    assert code == 1 and "findings[0]" in err, (code, out, err)

    # Vacuous-pass guard: empty checked[] rejected even on a clean pass.
    empty_checked = json.dumps({"contract_version": 1, "pass": True, "findings": [], "checked": []})
    code, out, err = run(empty_checked)
    assert code == 1 and "'checked' is empty" in err, (code, out, err)

    # Blank (whitespace-only or empty) summary/evidence/claim are schema-valid
    # non-empty-type but carry no content.
    blank_finding = json.dumps({"contract_version": 1, "pass": False,
                                 "findings": [{"summary": "  ", "evidence": "e"}],
                                 "checked": checked})
    code, out, err = run(blank_finding)
    assert code == 1 and "must not be blank" in err, (code, out, err)

    blank_checked = json.dumps({"contract_version": 1, "pass": True, "findings": [],
                                 "checked": [{"claim": "c", "evidence": ""}]})
    code, out, err = run(blank_checked)
    assert code == 1 and "must not be blank" in err, (code, out, err)

    # Narration echoing the return contract's own brace before the real JSON.
    echoed = 'Return {contract_version, pass, findings[], checked[]} as instructed.\n' + good
    code, out, err = run(echoed)
    assert code == 0 and json.loads(out) == json.loads(good), (code, out, err)

    # Decoy bypass: a fully schema-valid example quoted in narration ahead of
    # the agent's real, differently-valued verdict must be rejected as
    # ambiguous.
    decoy = json.dumps({"contract_version": 1, "pass": False, "findings": [], "checked": checked})
    real = json.dumps({"contract_version": 1, "pass": True,
                        "findings": [{"summary": "s", "evidence": "e"}], "checked": checked})
    code, out, err = run(f"Example shape: {decoy}\nActual result: {real}")
    assert code == 1 and "ambiguous" in err and out == "", (code, out, err)

    escalation = "I can't determine this safely.\nNEEDS-DECISION does file X own behavior Y?"
    code, out, err = run(escalation)
    assert code == 2 and out.strip().startswith("NEEDS-DECISION"), (code, out, err)

    # A fully valid verdict whose OWN evidence string legitimately quotes
    # "NEEDS-DECISION" must be accepted as the verdict, not misclassified as
    # an escalation.
    verdict_citing_escalation = json.dumps({
        "contract_version": 1,
        "pass": True, "findings": [],
        "checked": [{"claim": "attacker-brief.md documents its escape hatch",
                      "evidence": "attacker-brief.md tells it to return "
                                  "NEEDS-DECISION <question> instead of guessing"}],
    })
    code, out, err = run(verdict_citing_escalation)
    assert code == 0 and json.loads(out) == json.loads(verdict_citing_escalation), (code, out, err)

    print("check-verdict.py (idea-audit) selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        sys.exit(main())
