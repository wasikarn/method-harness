---
name: tech-humanize-th-standup-planted
tags: [tech-humanize, planted]
runs: 1
max_turns: 12
timeout_seconds: 600
allowed_tools: [Bash, Read, Edit, Write, Glob, Grep, Skill]
---
Use the `mh:tech-humanize` skill (Skill tool, `skill: "mh:tech-humanize"`) on `standup.md`. It is a daily standup for a Thai dev team (genre B, Thai with English tech terms). No writing sample is available.

Work through the skill's loop (draft, "still AI" bullets, final) in your turn, then make your final message the final rewrite only, verbatim, with nothing before or after it.
