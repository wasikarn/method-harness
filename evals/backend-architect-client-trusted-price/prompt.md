---
name: backend-architect-client-trusted-price
tags: [backend-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
`src/checkout/checkout_service.py` is our new checkout endpoint, about to go live. Review it
before launch — we want a second set of eyes on the design before real customers hit it. Use the
`mh:backend-architect` skill for this (Skill tool, `skill: "mh:backend-architect"`). Relay whatever it produces back to me in full, verbatim.
