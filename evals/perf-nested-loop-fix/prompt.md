---
name: perf-nested-loop-fix
tags: [performance-optimizer, clean]
runs: 3
max_turns: 25
timeout_seconds: 400
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Agent, Skill]
---
`findDuplicates` in `src/dedupe.js` is a bottleneck when processing large lists — `bench.js`
reproduces it. Use the `mh:performance-optimizer` skill for this (Skill tool, `skill: "mh:performance-optimizer"`). Run `node bench.js` before and after the fix so
the reported numbers are real. End with the full report as your final message.
