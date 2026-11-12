---
name: blind-hidden-callers
tags: [blind, refactor]
runs: 3
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Skill]
---
Rename `fmt_price` in `shop/money.py` to `format_money`, and make `currency` a required keyword-only argument
(drop the `"USD"` default).
