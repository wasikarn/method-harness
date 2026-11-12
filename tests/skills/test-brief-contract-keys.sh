#!/usr/bin/env bash
# A checker brief shows the JSON shape its agent must return. Codex is held to the schema by
# --output-schema, but a Claude checker only has the brief: a key the brief's example leaves out
# is a key the agent leaves out, and check-verdict.py then rejects a reply that followed the brief
# to the letter (idea-audit and compliance-audit both omitted contract_version, 2026-11-12).
# The examples are sketches, not valid JSON (`bool`, `<...>`, `{"id", "verdict"}`), so they cannot
# be piped through the checker. This reads the example block itself and fails when it lacks a key
# the schema requires at any depth, or shows another value where the schema fixes one (const).
# Every *brief*.md under a skill's references/ must be listed below, so a new brief cannot skip it.
# Three planted edits to real briefs prove the scan bites.
# Run standalone: bash tests/skills/test-brief-contract-keys.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import glob, json, os, re, sys

ROOT = os.path.abspath(sys.argv[1])
IDEA = "skills/workflow/idea-audit/references/attacker-output-schema.json"
DEEP = "skills/review/deep-audit/references/checker-output-schema.json"
COMPLIANCE = "skills/review/compliance-audit/references/verifier-output-schema.json"
# brief -> the schema its reply is checked against; None = the brief shows no reply shape.
PAIRS = {
    "skills/workflow/idea-audit/references/attacker-brief.md": IDEA,
    "skills/review/compliance-audit/references/verifier-brief.md": COMPLIANCE,
    "skills/review/attack-proposal/references/attacker-brief.md": IDEA,
    "skills/review/attack-proposal/references/validator-brief.md": DEEP,
    "skills/review/deep-audit/references/whole-picture-brief.md": None,
}
passed = failed = 0


def check(desc, ok):
    global passed, failed
    passed, failed = passed + bool(ok), failed + (not ok)
    print(("  PASS: " if ok else "  FAIL: ") + desc, file=sys.stdout if ok else sys.stderr)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def all_required(node):
    """Every key named by a `required` list anywhere in the schema."""
    out = []
    if isinstance(node, dict):
        out += [k for k in node.get("required", []) if isinstance(k, str)]
        for v in node.values():
            out += all_required(v)
    elif isinstance(node, list):
        for v in node:
            out += all_required(v)
    return out


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


def problems(text, schema):
    block = example(text, schema["required"])
    if block is None:
        return ["no JSON example naming two or more of %s" % schema["required"]]
    out = []
    missing = [k for k in dict.fromkeys(all_required(schema)) if '"%s"' % k not in block]
    if missing:
        out.append("example lacks required key(s): " + " ".join(missing))
    for key, prop in schema.get("properties", {}).items():
        if "const" in prop:
            want = '"%s":\\s*%s(?![\\w.])' % (re.escape(key), re.escape(json.dumps(prop["const"])))
            if not re.search(want, block):
                out.append('example does not show "%s": %s' % (key, json.dumps(prop["const"])))
    return out


print("=== each brief's example carries what its schema requires ===")
briefs = glob.glob(os.path.join(ROOT, "skills/*/*/references/*brief*.md"))
for rel in sorted(os.path.relpath(p, ROOT) for p in briefs):
    check("%s is listed in PAIRS" % rel, rel in PAIRS)
for rel, schema_rel in PAIRS.items():
    if not os.path.isfile(os.path.join(ROOT, rel)):
        check("%s exists" % rel, False)
        continue
    text = read(rel)
    if schema_rel is None:
        check("%s shows no reply shape (pair it with a schema if it starts to)" % rel,
              '"contract_version"' not in text)
        continue
    found_problems = problems(text, json.loads(read(schema_rel)))
    check("%s matches %s%s" % (rel, schema_rel, "".join("; " + p for p in found_problems)),
          not found_problems)

print("=== planted edits are caught ===")
idea_text = read("skills/workflow/idea-audit/references/attacker-brief.md")
idea_schema = json.loads(read(IDEA))
block = example(idea_text, idea_schema["required"]) or ""
dropped = block.replace('"contract_version": 1, ', "")
planted = idea_text.replace(block, dropped) + '\nThe host requires "contract_version".\n'
check("a key dropped from the example is caught even when prose still names it",
      dropped != block and bool(problems(planted, idea_schema)))
wrong = block.replace('"contract_version": 1', '"contract_version": 2')
check("a value the schema fixes is caught when the example shows another",
      wrong != block and bool(problems(idea_text.replace(block, wrong), idea_schema)))
ver_text = read("skills/review/compliance-audit/references/verifier-brief.md")
ver_schema = json.loads(read(COMPLIANCE))
block = example(ver_text, ver_schema["required"]) or ""
dropped = block.replace(', "output_tail"', "")
check("a nested required key dropped from the example is caught",
      dropped != block and bool(problems(ver_text.replace(block, dropped), ver_schema)))

print("%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$rc"
