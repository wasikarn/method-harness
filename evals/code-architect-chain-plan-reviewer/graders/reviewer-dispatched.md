---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?plan-reviewer"'
min: 1
---
The blueprint reached the second specialist: the session dispatched `mh:plan-reviewer` rather than
reviewing its own blueprint inline or skipping the review. This is the chain break the
fold-subagents article reports (a folded main loop answering without asking the next specialist).
Scored in both arms. In the fold arm this dispatch also shows up as `DELEGATED` on the
folded-Agent-calls line; for this case that call is the plan-reviewer handoff the prompt asks for,
not a folded code-architect delegating.
