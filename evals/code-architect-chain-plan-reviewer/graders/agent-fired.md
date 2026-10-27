---
type: regex
target: trace
match: not_contains
pattern: "Agent type '[^']*' not found\\. Available agents"
---
No "agent type not found" fallback happened for either agent in this chain: the pattern matches
any agent type, so a missing `mh:code-architect` or `mh:plan-reviewer` both fail it. This is the
guard for `reviewer-dispatched.md`, which as a `tool_used` check also matches a failed
`plan-reviewer` dispatch in a without-plugin arm. A `tool_used: Agent` check on the requested
`subagent_type` alone is a false positive here: the model still requests `mh:code-architect` even
when it doesn't exist, gets this exact tool error, and falls back — this checks for that literal
error string instead of a looser phrase that could appear in legitimate architecture discussion.
