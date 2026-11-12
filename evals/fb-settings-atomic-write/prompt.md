---
name: fb-settings-atomic-write
tags: [headroom, fair-blind]
runs: 5
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
need a saveSetting(key, value) in `src/settings.js` for the prefs screen. it should merge into whatever's already on disk. tray helper should pick up changes by itself, it already watches the file. add a test too
