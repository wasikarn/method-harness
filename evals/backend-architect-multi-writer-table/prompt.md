---
name: backend-architect-multi-writer-table
tags: [backend-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
We want to pull `src/services/fulfillment_service.py` out into its own deployable service, running
separately from the rest of `src/services/`. Before we do that split, review how
`src/services/order_service.py` and `src/services/fulfillment_service.py` currently interact — flag anything that would
cause problems once they're two separate services instead of two modules in one process. Use the
`mh:backend-architect` skill for this (Skill tool, `skill: "mh:backend-architect"`). Relay whatever it produces back to me in full, verbatim.
