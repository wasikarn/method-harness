---
type: regex
pattern: '(zero|no)[- ](runtime )?dependenc(?![^\n]{0,40}\bMATCH\b)[^\n]{0,250}(\bbut\b|contradict|\bGAP\b|mismatch|discrepan|\bfalse\b|untrue|not true)[^\n]{0,250}lodash|lodash[^\n]{0,250}(contradict|\bGAP\b|mismatch|discrepan|\bfalse\b|even though|despite)'
match: contains
target: last_message
flags: i
---
The report catches that SOURCE-PITCH.md's prose ("Zero runtime dependencies") contradicts its own
embedded package.json, which lists lodash: the claim is called false, a GAP or a discrepancy on the
same line as lodash, not accepted as MATCH. A regex, not an llm rubric: on 2026-11-06 the one-word
haiku judge voted FAIL 3/3 on a reply that said exactly this (GH #920).
