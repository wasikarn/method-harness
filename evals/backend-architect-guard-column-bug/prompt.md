---
name: backend-architect-guard-column-bug
tags: [backend-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
We're about to turn on multiple worker instances for `src/billing/charge_worker.py` so we can
process the charge queue faster. Before we do, review it for correctness under concurrent workers
— this handles real customer payments, so a double-charge would be bad. Use the
`mh:backend-architect` skill for this (Skill tool, `skill: "mh:backend-architect"`). Relay whatever it produces back to me in full, verbatim.
