---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?requirement-analyst"'
min: 1
arm: with-only
---
The session must dispatch the `mh:requirement-analyst` subagent rather than review inline.
