---
name: compliance-audit-planted
tags: [compliance-audit, planted]
runs: 1
max_turns: 40
timeout_seconds: 900
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Agent, AskUserQuestion]
---
/mh:compliance-audit target-repo/plan.md, commit range plan-base..plan-head in target-repo/

The plan and the implementation to audit against it are both in `target-repo/` (a small git repo
already set up here — read `target-repo/plan.md` for the two requirements, then audit the diff
between the `plan-base` and `plan-head` tags in that repo).
