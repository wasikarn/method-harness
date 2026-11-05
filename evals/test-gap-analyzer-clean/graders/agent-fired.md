---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?test-gap-analyzer"'
min: 1
arm: with-only
---
The session must dispatch the `mh:test-gap-analyzer` subagent rather than review inline.
