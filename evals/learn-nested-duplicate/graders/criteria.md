---
type: llm
---
PASS if the final message treats the rule about calling `trash` on an empty variable as already
saved (a duplicate of an existing memory) and offers the rule "run the linter before every commit"
as new. FAIL if it offers the trash rule as new, or drops the linter rule.
