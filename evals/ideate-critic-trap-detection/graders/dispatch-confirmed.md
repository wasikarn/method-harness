---
type: tool_used
tool: Agent
input_match: ideate-critic
min: 1
arm: with-only
---
Display-only trigger: confirms the specialized `mh:ideate-critic` agent was actually dispatched via the
Agent tool in this run (not just that the trace lacks an "agent not found" error — an empty trace,
or one where the model free-lanced an answer without ever calling the tool, would still pass
`agent-fired.md` vacuously). `arm: with-only` since this is the plugin's own dispatch
mechanism: in a two-arm run it is excluded from scoring in both arms and reported for visibility only
(the CLI does this on its own only for `tool: Skill`, not `tool: Agent`).
