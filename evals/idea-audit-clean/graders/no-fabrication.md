---
type: regex
pattern: '(zero|no)[- ](runtime )?dependenc[^\n.;]{0,80}\b(is|are|was) (false|untrue|wrong|contradicted)|(zero|no)[- ](runtime )?dependenc[^\n.;]{0,80}(?<!no )(?<!not )(?<!n.t )(?<!without )(?<!any )(\bGAP\b|contradict)|lists? (a |one |\d+ )?(runtime )?dependenc(y|ies) on|(pulls? in|depends on|brings in) lodash'
match: not_contains
target: last_message
flags: i
---
The report invents no dependency defect. SOURCE-PITCH.md's package.json block lists no dependencies,
so the "zero runtime dependencies" claim must not be called false, a GAP or contradicted, and no
dependency may be reported. The shapes are narrow on purpose (the claim called false in the same
clause, a GAP or contradiction not negated by no/not/without, a named dependency), because every
match fails the run: "no contradiction found" or "no lodash" passes. Known limit: a fabrication worded
another way ("misleading: depends on axios") is not caught. A regex, not an llm rubric: on
2026-11-06 the one-word haiku judge voted FAIL 3/3 on a reply that invented nothing (GH #920).
