---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?silent-failure-hunter"'
min: 1
arm: with-only
---
The session must dispatch the `mh:silent-failure-hunter` subagent rather than review inline.
