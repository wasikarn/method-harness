#!/usr/bin/env bash
# test-skill-dir-paths-resolve.sh — every ${CLAUDE_SKILL_DIR}/<path> named in a skill's markdown
# resolves to a file or dir, relative to that skill's own directory. attack-proposal reuses
# idea-audit's and deep-audit's checkers through ../ paths; harness-audit check 35 only checks
# that a script's basename exists somewhere, so a moved checker would leave these pointers dead
# with every other check green. A planted dead path proves the scan bites.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."

echo "=== \${CLAUDE_SKILL_DIR} paths in skills/ resolve ==="
python3 - "$ROOT" <<'PY'
import glob, os, re, sys

ROOT = os.path.abspath(sys.argv[1])
REF = re.compile(r"\$\{CLAUDE_SKILL_DIR\}(/[A-Za-z0-9_./-]+)")
passed = failed = 0


def check(desc, ok):
    global passed, failed
    passed, failed = passed + bool(ok), failed + (not ok)
    print(("  PASS: " if ok else "  FAIL: ") + desc, file=sys.stdout if ok else sys.stderr)


def skill_dir(path, top):
    d = os.path.dirname(path)
    while d.startswith(top) and not os.path.isfile(os.path.join(d, "SKILL.md")):
        d = os.path.dirname(d)
    return d


def dead_refs(top):
    out, total = [], 0
    for f in sorted(glob.glob(os.path.join(top, "skills", "**", "*.md"), recursive=True)):
        base = skill_dir(f, top)
        with open(f, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                for m in REF.finditer(line):
                    total += 1
                    rel = m.group(1).rstrip(".")
                    if not os.path.exists(os.path.normpath(base + rel)):
                        out.append("%s:%d: %s" % (os.path.relpath(f, top), i, rel))
    return out, total


bad, total = dead_refs(ROOT)
# 32 references at authoring time; the floor only proves the glob reached the skill tree.
check("scan found references (%d)" % total, total >= 10)
check("every reference resolves: " + (", ".join(bad) or "none dead"), not bad)

# Planted fixture: one live and one dead pointer in a throwaway skill tree.
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    sk = os.path.join(tmp, "skills", "b", "s")
    os.makedirs(os.path.join(sk, "scripts"))
    open(os.path.join(sk, "scripts", "ok.py"), "w").close()
    with open(os.path.join(sk, "SKILL.md"), "w") as fh:
        fh.write('python3 "${CLAUDE_SKILL_DIR}/scripts/ok.py"\npython3 "${CLAUDE_SKILL_DIR}/../gone/x.py"\n')
    planted, n = dead_refs(tmp)
    check("planted dead path is caught, live one is not (not vacuous)",
          n == 2 and len(planted) == 1 and planted[0].endswith("/../gone/x.py"))

print("=== Summary: %d passed, %d failed ===" % (passed, failed))
sys.exit(1 if failed else 0)
PY
