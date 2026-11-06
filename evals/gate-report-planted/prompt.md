---
name: gate-report-planted
tags: [gate-report, planted]
runs: 1
max_turns: 10
timeout_seconds: 300
allowed_tools: [Bash, Read, Glob, Grep]
---
/mh:gate-report

The gate-decisions journal for this workspace is `metrics/gate-decisions.jsonl`, not the default location, so run the report with `MH_GATE_JOURNAL_PATH=./metrics/gate-decisions.jsonl` in the environment. Bash is needed to run it.

Read the report back the way the skill says: quote its counts as printed, say how many times a gate actually blocked or interrupted work, and explain what the shadow-rule, session-less and non-UUID session id lines mean.
