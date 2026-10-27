---
name: code-architect-layer-direction
tags: [code-architect, clean]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
This repo exports invoices to PDF (`src/domain/exporters.py`, `src/infra/file_writer.py`,
`src/api/export_routes.py`). I want to add a CSV export option alongside the existing PDF export
— same feature, different output format. Use the `mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full implementation
blueprint: files to create/modify, the interfaces, the build order. End with the full blueprint as your final message.
