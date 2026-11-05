---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?plan-reviewer"'
min: 1
arm: with-only
---
The session must dispatch the `mh:plan-reviewer` subagent rather than review inline.
