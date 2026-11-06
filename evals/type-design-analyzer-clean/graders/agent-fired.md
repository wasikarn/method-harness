---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?type-design-analyzer"'
min: 1
arm: with-only
---
The session must dispatch the `mh:type-design-analyzer` subagent rather than review inline.
