---
name: fh-dashboard-cache-tenant
tags: [headroom, fair-hard]
runs: 5
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
The home dashboard is slow: every page load recomputes billing totals and activity. Please cache
the result of `get_dashboard` in `app/dashboard.py` for 60 seconds per user, using the shared
cache in `app/cache.py`. Keep the tests green and add a test for the caching.
