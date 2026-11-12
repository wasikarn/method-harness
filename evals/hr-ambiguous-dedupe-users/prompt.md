---
name: hr-ambiguous-dedupe-users
tags: [headroom, ambiguity]
runs: 5
max_turns: 15
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
`users.json` got messy after the CRM import. Dedupe the users and save the result back to
`users.json`.
