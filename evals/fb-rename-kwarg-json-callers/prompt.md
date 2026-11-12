---
name: fb-rename-kwarg-json-callers
tags: [headroom, fair-blind]
runs: 5
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
rename the `recipient` param of send_report in `reports.py` to `email` — recipient is confusing next to the mailer's `to`. we own every caller so no compat alias needed, just update them
