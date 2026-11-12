#!/usr/bin/env bash
# A checker brief shows the JSON shape its agent must return. Codex is held to the schema by
# --output-schema, but a Claude checker only has the brief: a key the brief's example leaves out
# is a key the agent leaves out, and check-verdict.py then rejects a reply that followed the brief
# to the letter (idea-audit and compliance-audit both omitted contract_version, 2026-11-12).
#
# The examples are sketches on purpose (`bool`, `<what goes here>`): each check-verdict.py rejects
# a message that holds two valid verdict objects as ambiguous, so a valid example the agent quoted
# back would sink its real answer. So this test fills each sketch in (placeholders and strings get
# a value of the type the schema names; numbers, true, false and null written in the sketch stay
# as written) and pipes the result through the skill's own check-verdict.py. The checker is the
# judge: a missing, misspelt or extra key at any depth, or a wrong fixed value, is rejected there.
# Every *brief*.md under a skill's references/ must be listed below, so a new brief cannot skip it.
# Planted edits to the real briefs prove the scan bites.
# Run standalone: bash tests/skills/test-brief-contract-keys.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import glob, json, os, re, subprocess, sys

ROOT = os.path.abspath(sys.argv[1])
IDEA = ("skills/workflow/idea-audit/references/attacker-output-schema.json",
        "skills/workflow/idea-audit/scripts/check-verdict.py")
DEEP = ("skills/review/deep-audit/references/checker-output-schema.json",
        "skills/review/deep-audit/scripts/check-verdict.py")
COMPLIANCE = ("skills/review/compliance-audit/references/verifier-output-schema.json",
              "skills/review/compliance-audit/scripts/check-verdict.py")
# brief -> (schema, checker) its reply goes through; None = the brief shows no reply shape.
PAIRS = {
    "skills/workflow/idea-audit/references/attacker-brief.md": IDEA,
    "skills/review/compliance-audit/references/verifier-brief.md": COMPLIANCE,
    "skills/review/attack-proposal/references/attacker-brief.md": IDEA,
    "skills/review/attack-proposal/references/validator-brief.md": DEEP,
    "skills/review/deep-audit/references/whole-picture-brief.md": None,
}
PLACEHOLDER = "\x01"  # marks a value the sketch left open; the text after it is the sketch's own
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
passed = failed = 0


def check(desc, ok):
    global passed, failed
    passed, failed = passed + bool(ok), failed + (not ok)
    print(("  PASS: " if ok else "  FAIL: ") + desc, file=sys.stdout if ok else sys.stderr)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def balanced(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return None


def example(text, top):
    """The first {...} block that names at least two of the schema's top-level keys."""
    for m in re.finditer(r'\{"', text):
        block = balanced(text, m.start())
        if block and sum('"%s"' % k in block for k in top) >= 2:
            return block
    return None


def open_value(m):
    return json.dumps(PLACEHOLDER + m.group(0))


def parse_sketch(block):
    """The sketch as a tree: an open value (`bool`, `<...>`) becomes a PLACEHOLDER string."""
    flat = re.sub(r"\s+", " ", block)
    out, pos = [], 0
    for m in list(STRING.finditer(flat)) + [None]:
        gap = flat[pos : m.start() if m else len(flat)]
        gap = re.sub(r"\[\s*(?:<[^<>]*>|\.\.\.)\s*\]", "[]", gap)
        gap = re.sub(r"<[^<>]*>|\bbool\b", open_value, gap)
        out.append(gap.replace("...", ""))
        if m:
            out.append(m.group(0))
            pos = m.end()
    return json.loads("".join(out))


def filled(node, schema):
    """A value of the type the schema names, wherever the sketch has a string or an open value."""
    schema = schema or {}
    if isinstance(node, dict):
        props = schema.get("properties", {})
        return {k: filled(v, props.get(k)) for k, v in node.items()}
    if isinstance(node, list):
        return [filled(v, schema.get("items")) for v in node]
    if not isinstance(node, str):
        return node
    kinds = schema.get("type", "string")
    kinds = [kinds] if isinstance(kinds, str) else kinds
    said = node[1:].lstrip("<") if node.startswith(PLACEHOLDER) else ""
    if "null" in kinds and said.startswith("null"):
        return None
    if "enum" in schema:
        return schema["enum"][0]
    if "boolean" in kinds:
        return True
    if "integer" in kinds:
        return 0
    for candidate in ("README.md:1", "abcdef0"):  # a citation shape, then a short commit SHA
        if re.search(schema.get("pattern", ""), candidate):
            return candidate
    return "README.md:1"


def verdict(block, schema, checker):
    """(accepted, reason): the sketch, filled in, through the skill's own check-verdict.py."""
    try:
        reply = json.dumps(filled(parse_sketch(block), schema))
    except ValueError as e:
        return False, "the example is not a readable sketch: %s" % e
    run = subprocess.run([sys.executable, "-B", os.path.join(ROOT, checker)], input=reply,
                         capture_output=True, text=True)
    return run.returncode == 0, run.stderr.strip().splitlines()[-1] if run.stderr.strip() else ""


def brief_verdict(text, pair):
    schema = json.loads(read(pair[0]))
    block = example(text, schema["required"])
    if block is None:
        return False, "no JSON example naming two or more of %s" % schema["required"], None
    ok, reason = verdict(block, schema, pair[1])
    return ok, reason, block


print("=== a reply shaped like each brief's example is accepted by its checker ===")
briefs = glob.glob(os.path.join(ROOT, "skills/*/*/references/*brief*.md"))
for rel in sorted(os.path.relpath(p, ROOT) for p in briefs):
    check("%s is listed in PAIRS" % rel, rel in PAIRS)
for rel, pair in PAIRS.items():
    if not os.path.isfile(os.path.join(ROOT, rel)):
        check("%s exists" % rel, False)
        continue
    text = read(rel)
    if pair is None:
        check("%s shows no reply shape (pair it with a checker if it starts to)" % rel,
              '"contract_version"' not in text)
        continue
    ok, reason, block = brief_verdict(text, pair)
    why = "" if ok else " -- " + reason
    check("%s: %s accepts the example's shape%s" % (rel, pair[1], why), ok)
    if block is not None:
        raw = subprocess.run([sys.executable, "-B", os.path.join(ROOT, pair[1])], input=block,
                             capture_output=True, text=True)
        check("%s: the example as written is a sketch, not a second valid verdict" % rel,
              raw.returncode == 1)

print("=== planted edits are caught ===")


def planted(rel, desc, old, new, extra=""):
    pair, text = PAIRS[rel], read(rel)
    block = example(text, json.loads(read(pair[0]))["required"]) or ""
    edited = block.replace(old, new)
    ok, _, _ = brief_verdict(text.replace(block, edited) + extra, pair)
    check(desc, edited != block and not ok)


IDEA_BRIEF = "skills/workflow/idea-audit/references/attacker-brief.md"
VERIFIER = "skills/review/compliance-audit/references/verifier-brief.md"
planted(IDEA_BRIEF, "a key dropped from the example is caught even when prose still names it",
        '"contract_version": 1, ', "", '\nThe host requires "contract_version".\n')
planted(IDEA_BRIEF, "a fixed value shown wrong is caught",
        '"contract_version": 1', '"contract_version": 2')
planted(IDEA_BRIEF, "a key the checker does not know is caught",
        '"pass":', '"confidence": "<high|low>", "pass":')
planted(VERIFIER, "a nested key dropped from the example is caught",
        '"output_tail": "<the last lines it printed>"', '"sha2": "<x>"')
planted("skills/review/attack-proposal/references/validator-brief.md",
        "a misspelt key is caught", '"unexpected_files"', '"unexpected_file"')

print("%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$rc"
