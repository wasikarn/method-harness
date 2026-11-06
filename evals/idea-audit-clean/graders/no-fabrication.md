---
type: regex
pattern: '(zero|no)[- ](runtime )?dependenc[^\n]{0,250}(contradict|\bGAP\b|mismatch|discrepan|\bfalse\b|untrue|not true)|lodash|(lists?|declares?|pulls? in|ships? with) (a |one |\d+ )?(runtime )?dependenc'
match: not_contains
target: last_message
flags: i
---
The report invents no dependency defect. SOURCE-PITCH.md's package.json block lists no dependencies,
so the "zero runtime dependencies" claim must not be called false, a GAP or a discrepancy, and no
dependency (lodash or any other) may be reported. A regex, not an llm rubric: on 2026-11-06 the
one-word haiku judge voted FAIL 3/3 on a reply that invented nothing (GH #920).
