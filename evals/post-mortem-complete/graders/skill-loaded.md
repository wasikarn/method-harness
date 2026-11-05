---
type: regex
pattern: 'Four inputs or no draft'
match: contains
target: trace
arm: with-only
---
The skill body reached the session: user invocation by slash command is not a Skill tool call, so the proof is the skill's own text in the trace, not `tool_used: Skill`.
