---
name: ideate-run
tags: [ideate, run]
runs: 1
max_turns: 40
allowed_tools: [Agent, Bash, Read, Glob, Grep, Skill]
timeout_seconds: 900
---
brainstorm: use the `mh:ideate` skill (Skill tool, `skill: "mh:ideate"`) on the problem in `PROBLEM.md`. Run the full algorithm as the skill states it, then render the output shape as your final message.
