---
name: gate-report-not-set-up
tags: [gate-report, clean]
runs: 1
max_turns: 8
timeout_seconds: 300
allowed_tools: [Bash, Read, Glob, Grep]
---
/mh:gate-report

The gate-decisions journal for this workspace would be `metrics/gate-decisions.jsonl`, not the default location, so run the report with `MH_GATE_JOURNAL_PATH=./metrics/gate-decisions.jsonl` in the environment. Bash is needed to run it.

Report what the skill reports.
