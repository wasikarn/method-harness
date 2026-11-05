#!/usr/bin/env bash
# .claude/settings.json's merge ask rules prompt on every run of scripts/merge-pr.sh and not on reads
# of it or runs of its test (GH #907, #909). merge-pr.sh runs `gh pr merge` in its own subprocess,
# so these rules are the only prompt before that merge.
# The matcher is a model of Claude Code's: `*` = any text, quotes literal, case-sensitive, runs of
# spaces/tabs collapsed, tested on the whole command and on each subcommand (CC 2.1.318 binary read
# in #909). A live prompt is the final check; this test catches a rule set narrowed by mistake.
# Run standalone: bash tests/scripts/test-merge-ask-rules.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT/.claude/settings.json" <<'PY'
import json, re, sys
from fnmatch import fnmatchcase

rules = [r[5:-1] for r in json.load(open(sys.argv[1]))["permissions"]["ask"] if r.startswith("Bash(")]

def parts(cmd):
    cmd = re.sub(r"[ \t]+", " ", cmd)
    out = [cmd]
    for sep in ("&&", "||", ";", "|", "&", "\n"):
        out = [p for chunk in out for p in chunk.split(sep)]
    return [cmd] + [p.strip() for p in out if p.strip()]

def asks(cmd):
    return any(fnmatchcase(p, r) for r in rules for p in parts(cmd))

MUST_ASK = [
    "bash scripts/merge-pr.sh 904",
    "scripts/merge-pr.sh 904",
    "./scripts/merge-pr.sh 904",
    "bash scripts/merge-pr.sh --verify 904 " + "a" * 40 + " develop comments.json",
    "nohup bash scripts/merge-pr.sh 904 > log 2>&1 &",
    "gh pr comment 904 --body-file s.md && env scripts/merge-pr.sh 904",  # #907 F1
    'gh pr comment 904 --body "Fresh-context review: MERGE @ abc" && bash scripts/merge-pr.sh 904 && claude plugin update mh@wasikarn',
    'bash "scripts/merge-pr.sh" 904',  # #909: quoted path
    "bash '$HOME/Codes/Personals/method-harness/scripts/merge-pr.sh' 904",
    'cd scripts && bash "merge-pr.sh" 904',
    "cd scripts && bash 'merge-pr.sh' 904",
    "echo 904 | xargs bash scripts/merge-pr.sh",  # #909: PR number on stdin
    "cd scripts && bash merge-pr.sh 904",  # #909: no scripts/ prefix
    "cd scripts && ./merge-pr.sh 904",
    "bash\tscripts/merge-pr.sh\t904",
]
MUST_NOT_ASK = [
    "sed -n 30,75p scripts/merge-pr.sh",
    "rtk read scripts/merge-pr.sh",
    "git log --oneline -- scripts/merge-pr.sh",
    'bash tests/scripts/test-merge-pr.sh 2>&1 | /usr/bin/grep -E "FAIL|self-test"',
    'bash "tests/scripts/test-merge-pr.sh" 2>&1 | tail -3',  # #909 attacker: B1
    "bash 'tests/scripts/test-merge-pr.sh' 2>&1",
    "git push -u origin feat/merge-pr-read-gotcha",
    "gh pr comment 904 --body-file review-summary.md",
]

fail = 0
for want, cases in ((True, MUST_ASK), (False, MUST_NOT_ASK)):
    for c in cases:
        if asks(c) != want:
            fail += 1
            print(f"FAIL: {'should ask' if want else 'should not ask'}: {c!r}")
print(f"{len(MUST_ASK) + len(MUST_NOT_ASK) - fail} passed, {fail} failed")
sys.exit(1 if fail else 0)
PY
status=$?
[ "$status" -eq 0 ] && echo "PASS: test-merge-ask-rules"
exit "$status"
