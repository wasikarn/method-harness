---
type: regex
pattern: '^- .*ครับ\s*$[\s\S]*^- .*ครับ\s*$'
match: not_contains
flags: m
target: last_message
---
The terse bullets no longer end in `ครับ` line after line: at most one bullet keeps the particle.
Replaces part of the llm `criteria` grader (GH #921). Limit: only bullets that start with `- `
are counted.
