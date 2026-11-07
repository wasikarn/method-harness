#!/usr/bin/env bash
# test-eval-subjects-doc.sh: the eval subjects named in docs/reference/operating-model.md
# (the bullet on `claude plugin eval`'s native layout) must equal the subjects that have
# a case under evals/ (GH #415). Pins only the documented set; it does not require an eval
# for every agent or skill.
#
# A subject is an agent (agents/<name>.md) or skill (skills/*/<name>/SKILL.md). A case's
# subject is the first entry of `tags:` in its prompt.md frontmatter, falling back to the
# longest agent/skill name its directory name starts with (some cases carry no tags).
# Doc side: every backticked token in that bullet that is an agent or skill name.
set -uo pipefail
ROOT="$(cd -P "$(dirname "$0")/../.." && pwd)"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
surfaces = {f[:-3] for f in os.listdir(os.path.join(root, "agents")) if f.endswith(".md")}
for dirpath, _, files in os.walk(os.path.join(root, "skills")):
    if "SKILL.md" in files:
        surfaces.add(os.path.basename(dirpath))

evals_dir = os.path.join(root, "evals")
case_subjects = {}
errors = []
for case in sorted(os.listdir(evals_dir)):
    cdir = os.path.join(evals_dir, case)
    if not os.path.isdir(cdir) or case == "results":
        continue
    subject = None
    prompt = os.path.join(cdir, "prompt.md")
    if os.path.isfile(prompt):
        m = re.search(r"^tags:\s*\[\s*([^,\]\s]+)", open(prompt).read(), re.M)
        if m:
            subject = m.group(1)
    if subject is None:
        prefixes = [s for s in surfaces if case.startswith(s + "-")]
        subject = max(prefixes, key=len) if prefixes else None
    if subject is None:
        errors.append("evals/%s: no tags and no agent/skill name prefix" % case)
        continue
    case_subjects.setdefault(subject, []).append(case)

doc = open(os.path.join(root, "docs/reference/operating-model.md")).read()
bullet = None
for b in re.split(r"\n(?=- )", doc):
    if "claude plugin eval`'s native layout" in b:
        bullet = b
        break
if bullet is None:
    print("FAIL: operating-model.md has no bullet on `claude plugin eval`'s native layout")
    sys.exit(1)
# A doctrine subject (e.g. `rule4`, a METHODOLOGY rule graded on a plain task) is no agent or
# skill, so it counts once the bullet names it and a case carries it as its first tag.
doc_subjects = {t for t in re.findall(r"`([^`\s]+)`", bullet) if t in surfaces or t in case_subjects}

have = set(case_subjects)
for s in sorted(have - doc_subjects):
    errors.append("evals/ has cases for `%s` (%s) but operating-model.md does not name it"
                  % (s, ", ".join(case_subjects[s])))
for s in sorted(doc_subjects - have):
    errors.append("operating-model.md names `%s` but evals/ has no case for it" % s)

for e in errors:
    print("FAIL: " + e)
if errors:
    sys.exit(1)
print("PASS: %d eval subjects match operating-model.md" % len(have))
PY
