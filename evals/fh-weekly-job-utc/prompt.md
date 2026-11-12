---
name: fh-weekly-job-utc
tags: [headroom, fair-hard]
runs: 5
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
Finance wants the weekly summary in their inbox before they get in on Monday. Please schedule
`reports.weekly.send_summary` to run every Monday at 02:00 Bangkok time. The schedule lives in
`config/schedule.json`.
