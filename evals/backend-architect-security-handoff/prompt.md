---
name: backend-architect-security-handoff
tags: [backend-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
We're about to launch order search for our support team (`src/search/search_service.py`,
`src/support/routes.py`). Review the overall design before launch — how it fits with the rest of
the order system, the caching approach, anything else that stands out. Use the
`mh:backend-architect` skill for this (Skill tool, `skill: "mh:backend-architect"`). Relay whatever it produces back to me in full, verbatim.
