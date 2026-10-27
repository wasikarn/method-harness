---
name: code-architect-disqualified-analog
tags: [code-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
I want to add a `MonthlySummaryReportGenerator` that compiles monthly stats and emails them to a
distribution list — basically the same shape as `src/reports/legacy_report_generator.py`, just a
different report. Use the `mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full implementation blueprint: files to
create/modify, the interfaces, the build order. End with the full blueprint as your final message.
