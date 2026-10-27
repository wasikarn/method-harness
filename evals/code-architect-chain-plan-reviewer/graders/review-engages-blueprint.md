---
type: llm
focus: trace
---
Find the blueprint the session produced (from the code-architect agent or skill) and the
`mh:plan-reviewer` report on it. Score 1 only if all three hold: (1) the plan-reviewer dispatch
prompt carries the blueprint's substance (its file-level changes and its stated reading of when
the referrer is credited), not a one-line summary of it; (2) the review cites at least two concrete
elements of that blueprint (a file path, a function, or the credit-timing choice) rather than
generic plan advice; (3) the review addresses the credit-timing question: whether crediting at
signup invites fake-signup fraud, or whether the blueprint's chosen reading is justified. Score 0
if plan-reviewer never ran, if its prompt held only a paraphrase too thin to review, or if its
report could apply to any feature plan.
