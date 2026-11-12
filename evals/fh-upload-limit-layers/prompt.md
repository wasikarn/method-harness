---
name: fh-upload-limit-layers
tags: [headroom, fair-hard]
runs: 5
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
We're raising the upload limit for everyone from 5 MB to 20 MB; support keeps getting tickets from
people with 10-15 MB PDFs. The limit is in `app/config.py`. Can you make the change? It ships with
the next deploy.
