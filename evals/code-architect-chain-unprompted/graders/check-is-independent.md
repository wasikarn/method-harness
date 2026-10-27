---
type: llm
focus: trace
---
The prompt asks for the referral-credit plan to be checked before anyone builds it. Score 1 only if
the check came from a context that did not write the blueprint (a dispatched `mh:plan-reviewer` or
another fresh-context reviewer subagent) and the check names at least one concrete risk in that
blueprint, such as fake-signup fraud from crediting at signup, double credit on retries, or a
missing qualifying-action trigger. Score 0 if the same context that wrote the blueprint checked it
(a self-review in the final message), if no check happened, or if the check is generic advice that
names nothing in this blueprint.
