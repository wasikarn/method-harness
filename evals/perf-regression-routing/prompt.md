---
name: perf-regression-routing
tags: [performance-optimizer, clean]
runs: 3
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Agent, Skill]
---
`calculateShipping` in `src/checkout.js` used to take about 5ms and now takes 2 full seconds after
a change we merged this morning. Nothing about the cart size changed. Can you fix it?
