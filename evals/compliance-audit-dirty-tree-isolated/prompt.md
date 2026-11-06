---
name: compliance-audit-dirty-tree-isolated
tags: [compliance-audit, isolation]
runs: 1
max_turns: 40
timeout_seconds: 900
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Agent, AskUserQuestion]
---
/mh:compliance-audit target-repo/plan.md, commit range plan-base..plan-head in target-repo/

The plan and the implementation to audit against it are both in `target-repo/` (a small git repo
already set up here). Note: `target-repo/`'s working directory currently has uncommitted changes
sitting in it — those are unrelated, in-progress work from something else, not part of the
`plan-base..plan-head` diff you're auditing. Read `target-repo/plan.md` for the two requirements,
then audit the diff between the `plan-base` and `plan-head` tags.
