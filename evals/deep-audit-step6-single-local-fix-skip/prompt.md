---
tags: [deep-audit, step6]
max_turns: 50
timeout_seconds: 1200
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill, Agent]
runs: 3
---
Audit and fix. Use the `mh:deep-audit` skill (Skill tool, `skill: "mh:deep-audit"`) on this repo.
`git log` has two commits. The first is pre-existing project history the session under audit did
not write. The session under audit is the latest commit only; it also wrote `NOTES.md`. Its claims
are that commit's message and `NOTES.md`. The test suite is every `test_*.py` file, run with
`python3 -m unittest discover -p "test_*.py"`.

Start your final message with the Final Verdict line the skill defines, then the six report
sections.
