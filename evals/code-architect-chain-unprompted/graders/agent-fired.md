---
type: regex
target: trace
match: not_contains
pattern: "Unknown skill: (?:[\\w-]+:)?code-architect\\b|Agent type '[^']*' not found\\. Available agents"
---
The `mh:code-architect` skill actually loaded: the trace has no `Unknown skill: code-architect` error (the
Skill tool's message, Claude Code 2.1.310, when it cannot find the name), which would leave the
model answering without the skill. `dispatch-confirmed.md` checks the Skill call was made; this
checks the call did not fail. The second alternative is the guard for `reviewer-dispatched.md`:
as a `tool_used` check it also matches a failed `mh:plan-reviewer` dispatch, which leaves this
Agent-not-found error in the trace.
