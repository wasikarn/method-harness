---
name: requirement-analyst-clean
tags: [requirement-analyst, clean]
runs: 1
max_turns: 12
timeout_seconds: 600
---
Use the `mh:requirement-analyst` skill (Skill tool, `skill: "mh:requirement-analyst"`) to analyse the ticket in `ticket.md` for readiness before implementation. The ticket body is that file; no fetch is needed.
The files are in the current working directory: `ticket.md`.

Return the skill's report verbatim as your final message. Add nothing before or after it.
