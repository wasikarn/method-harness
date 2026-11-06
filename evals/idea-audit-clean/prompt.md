---
name: idea-audit-clean
tags: [idea-audit, clean]
runs: 1
max_turns: 60
timeout_seconds: 1200
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill, Agent]
---
Use the `mh:idea-audit` skill (Skill tool, `skill: "mh:idea-audit"`) to evaluate whether to adopt
`SOURCE-PITCH.md` (a local file — pass it as the source, do not fetch anything over the network)
into this repo. `package.json` and `src/index.js` are this repo's current state; there is no
existing retry helper here.

Start your final message with the Phase 3 scored decision, and include the per-claim verdict table
in that message.
