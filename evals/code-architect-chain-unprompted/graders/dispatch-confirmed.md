---
type: tool_used
tool: Agent
input_match: code-architect
min: 1
---
Display-only trigger: confirms the specialized `mh:code-architect` agent was actually dispatched via the
Agent tool in this run (not just that the trace lacks an "agent not found" error — an empty trace,
or one where the model free-lanced an answer without ever calling the tool, would still pass
`agent-fired.md` vacuously). `arm` is left unset since this is the plugin's own dispatch
mechanism: excluded from scoring in both arms, reported for visibility only.
