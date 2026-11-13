---
name: attack-proposal-prefix-bypass
tags: [attack-proposal, planted]
runs: 1
max_turns: 80
timeout_seconds: 3600
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill, Agent]
---
Use the `mh:attack-proposal` skill (Skill tool, `skill: "mh:attack-proposal"`) on the fix proposed
in `PROPOSAL.md` before anyone builds it. `src/storage.py` is the current code the fix would change.
Work offline: no network.

End your final message with the skill's report, verdict line included.
