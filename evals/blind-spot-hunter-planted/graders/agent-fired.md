---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?blind-spot-hunter"'
min: 1
arm: with-only
---
The session must dispatch the `mh:blind-spot-hunter` subagent rather than review inline.
