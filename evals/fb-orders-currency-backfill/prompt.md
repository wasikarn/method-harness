---
name: fb-orders-currency-backfill
tags: [headroom, fair-blind]
runs: 5
max_turns: 15
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
orders needs a currency column now (3-letter ISO code, not null). can you add the next migration? I'll update checkout to write it in a separate PR
