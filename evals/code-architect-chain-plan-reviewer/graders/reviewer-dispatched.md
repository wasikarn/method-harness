---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?plan-reviewer"'
min: 1
---
The blueprint reached the second specialist: the session dispatched `mh:plan-reviewer` rather than
reviewing its own blueprint inline or skipping the review. This is the chain break the
fold-subagents article reports (a folded main loop answering without asking the next specialist).
`mh:plan-reviewer` is still an agent, so this stays an Agent check after code-architect became a skill.
