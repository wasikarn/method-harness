"""Shared verdict-JSON helpers for the check-verdict.py / check-citations.py scripts of
idea-audit, deep-audit and compliance-audit. The one home for these definitions:
tests/skills/test-check-verdict-drift.sh fails on a copy anywhere else."""
import json
import re

# A backticked command, or a path:line cite.
CITATION_RE = re.compile(r"`[^`]+`|(?=[^\s:`]*[A-Za-z])[^\s:`]*[./][^\s:`]*:\d+")


def mask_json_spans(text):
    """Replace every substring that parses as a JSON value (starting at each
    '{') with spaces, same length. Used so a NEEDS-DECISION match found only
    inside an otherwise-valid verdict's own string field (e.g. an `evidence`
    value that legitimately cites this escape hatch by name) isn't mistaken
    for a real escalation -- only a match that survives outside every parsed
    JSON span counts. Found by mh:deep-audit 2026-09-19: the escalation scan
    ran on raw, unmasked text, so a fully valid verdict whose own evidence
    string quoted "NEEDS-DECISION" got discarded and misreported as an
    escalation."""
    dec = json.JSONDecoder()
    masked = list(text)
    i = text.find("{")
    while i != -1:
        try:
            _, end = dec.raw_decode(text, i)
        except ValueError:
            i = text.find("{", i + 1)
            continue
        for j in range(i, end):
            masked[j] = " "
        i = text.find("{", end)
    return "".join(masked)


def extract_object(text):
    """First object that merely parses as JSON, valid or not -- used only for
    error-reporting once no schema-valid candidate exists."""
    dec = json.JSONDecoder()
    i = text.find("{")
    while i != -1:
        try:
            obj, _ = dec.raw_decode(text, i)
            return obj
        except ValueError:
            i = text.find("{", i + 1)
    return None


def extract_valid_candidates(text, validate):
    """Every object anywhere in the text for which validate(obj)[0] is true,
    deduplicated by content. More than one distinct candidate is ambiguous:
    a nested item never qualifies (it lacks the other required keys), so this
    only fires on two or more full verdict-shaped objects -- e.g. a decoy
    example ahead of the agent's real answer."""
    dec = json.JSONDecoder()
    seen = {}
    i = text.find("{")
    while i != -1:
        try:
            obj, _ = dec.raw_decode(text, i)
        except ValueError:
            i = text.find("{", i + 1)
            continue
        if isinstance(obj, dict) and validate(obj)[0]:
            seen[json.dumps(obj, sort_keys=True)] = obj
        i = text.find("{", i + 1)
    return list(seen.values())
