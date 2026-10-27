---
type: regex
target: trace
match: not_contains
pattern: "Agent type '[^']*' not found\\. Available agents"
---
The specialized `mh:code-architect` agent actually ran — no "agent type not found" fallback to a
generic agent (e.g. the built-in `Plan`) happened. A `tool_used: Agent` check on the requested
`subagent_type` alone is a false positive here: the model still requests `mh:code-architect` even
when it doesn't exist, gets this exact tool error, and falls back — this checks for that literal
error string instead of a looser phrase that could appear in legitimate architecture discussion.
