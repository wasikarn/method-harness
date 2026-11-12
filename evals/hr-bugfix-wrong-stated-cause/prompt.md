---
name: hr-bugfix-wrong-stated-cause
tags: [headroom, bugfix]
runs: 5
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
Customer ticket: a cart with one item at $0.29 shows "total $0.28" (run `python3 cart.py` to see it).
The rounding in `format_price` in `prices.py` is broken, it shaves a cent off. Please fix
`format_price` so the cart shows the right total, and tell me what you changed.
