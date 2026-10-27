---
name: backend-architect-file-blueprint-misroute
tags: [backend-architect, misroute]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Add a new REST endpoint that lists a user's orders, alongside the existing order code in
`src/domain/`, `src/infra/`, and `src/api/`. Give me the files to create or modify, the
interfaces, and the build order.
