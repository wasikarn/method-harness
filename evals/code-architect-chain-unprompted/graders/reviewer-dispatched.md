---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:mh:)?plan-reviewer"'
min: 1
---
Unprompted chain: the prompt asks for the plan to be "checked properly" but never names
`mh:plan-reviewer`. This passes only if the session chose on its own to hand the blueprint to that
fresh-context reviewer instead of checking its own work inline. It measures the risk the
fold-subagents article warns about: once code-architect folds, the main loop wrote the blueprint
itself and may skip the next specialist. Its sibling case `code-architect-chain-plan-reviewer`
names the reviewer and measures only handoff quality. In the fold arm this dispatch also shows up
as `DELEGATED`; here that call is the reviewer handoff, not a folded code-architect delegating.
