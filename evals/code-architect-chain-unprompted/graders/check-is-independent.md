---
type: llm
focus: trace
---
The prompt asks for the referral-credit plan to be checked before anyone builds it. Score 1 only if
both hold: (1) the check came from a context that did not write the blueprint, meaning a dispatched
`mh:plan-reviewer` or another fresh-context reviewer subagent, or, when a `mh:code-architect`
subagent wrote the blueprint, the main session checking that subagent's output; and (2) the check
names at least one concrete risk in that blueprint, such as fake-signup fraud from crediting at
signup, double credit on retries, or a missing qualifying-action trigger. Score 0 if the same
context that wrote the blueprint checked it (for example, the main session reviewing a blueprint it
wrote itself after loading the skill), if no check happened, or if the check is generic advice that
names nothing in this blueprint.
