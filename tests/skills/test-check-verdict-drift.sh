#!/usr/bin/env bash
# test-check-verdict-drift.sh — ratchet: the verdict-JSON helpers (mask_json_spans, extract_object,
# extract_valid_candidates, CITATION_RE) live only in scripts/_lib/verdict_json.py. Three skills
# once kept hand copies, which drifted (2026-09-20, #392); the "copies on purpose" reason no longer
# held once these skills already called ${CLAUDE_SKILL_DIR}/../../../scripts/_lib/ from SKILL.md.
# Fails on any redefinition elsewhere under skills/ or scripts/; a planted copy proves the scan bites.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."

echo "=== verdict-JSON helpers are defined only in scripts/_lib/verdict_json.py ==="
python3 - "$ROOT" <<'PY'
import ast, glob, os, subprocess, sys

ROOT = os.path.abspath(sys.argv[1])
HOME_FILE = os.path.join(ROOT, "scripts", "_lib", "verdict_json.py")
FUNCS = {"mask_json_spans", "extract_object", "extract_valid_candidates"}
passed = failed = 0


def check(desc, ok):
    global passed, failed
    passed, failed = passed + bool(ok), failed + (not ok)
    print(("  PASS: " if ok else "  FAIL: ") + desc, file=sys.stdout if ok else sys.stderr)


def copies(src):
    out = []
    for n in ast.walk(ast.parse(src)):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in FUNCS:
            out.append(n.name)
        elif isinstance(n, (ast.Assign, ast.AnnAssign)):
            targets = n.targets if isinstance(n, ast.Assign) else [n.target]
            if any(isinstance(t, ast.Name) and t.id == "CITATION_RE" for t in targets):
                out.append("CITATION_RE")
    return out


files = sorted(set(glob.glob(ROOT + "/skills/**/*.py", recursive=True)
                   + glob.glob(ROOT + "/scripts/**/*.py", recursive=True)))
check("scan found python files (%d)" % len(files), len(files) > 10)
check("scripts/_lib/verdict_json.py exists and defines all four",
      os.path.isfile(HOME_FILE) and set(copies(open(HOME_FILE, encoding="utf-8").read())) == FUNCS | {"CITATION_RE"})
bad = []
for f in files:
    if os.path.abspath(f) == HOME_FILE:
        continue
    for name in copies(open(f, encoding="utf-8").read()):
        bad.append("%s:%s" % (os.path.relpath(f, ROOT), name))
check("no copies outside _lib: " + (", ".join(bad) or "none"), not bad)

planted = "import re\nCITATION_RE = re.compile('x')\nclass K:\n    def extract_object(self, t):\n        return t\n"
check("planted copies are caught (not vacuous)", copies(planted) == ["CITATION_RE", "extract_object"])

for rel in ("skills/workflow/idea-audit/scripts/check-verdict.py",
            "skills/review/deep-audit/scripts/check-verdict.py",
            "skills/review/compliance-audit/scripts/check-verdict.py",
            "skills/workflow/idea-audit/scripts/check-citations.py"):
    r = subprocess.run([sys.executable, os.path.join(ROOT, rel), "--selftest"], capture_output=True, text=True)
    check("%s --selftest exits 0" % rel, r.returncode == 0)
print("=== Summary: %d passed, %d failed ===" % (passed, failed))
sys.exit(1 if failed else 0)
PY
