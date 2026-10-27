---
name: perf-shallow-copy-trap
tags: [performance-optimizer, planted]
runs: 3
max_turns: 25
timeout_seconds: 400
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Agent, Skill]
---
`cloneUserSettings` in `src/settings.js` is on a hot path and `bench.js` shows it's slow (it's
called on every request). Optimize it. Use the `mh:performance-optimizer` skill for this (Skill tool, `skill: "mh:performance-optimizer"`). Relay whatever it
produces back to me in full, verbatim.
