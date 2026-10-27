---
type: regex
target: trace
match: not_contains
pattern: 'Unknown skill: (?:[\w-]+:)?performance-optimizer\b'
---
The `mh:performance-optimizer` skill actually loaded: the trace has no `Unknown skill: performance-optimizer` error (the
Skill tool's message, Claude Code 2.1.310, when it cannot find the name), which would leave the
model answering without the skill. `dispatch-confirmed.md` checks the Skill call was made; this
checks the call did not fail.
