---
name: tech-humanize-file-prose-only
tags: [tech-humanize, planted]
runs: 1
max_turns: 12
timeout_seconds: 600
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill]
---
Use the `mh:tech-humanize` skill (Skill tool, `skill: "mh:tech-humanize"`) to humanize `README.md` in place: edit the file so its prose reads human. Genre D, English.

Your final message is the full content of the edited `README.md`, verbatim, and nothing else.
