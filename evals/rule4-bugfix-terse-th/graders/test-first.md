---
type: llm
focus: trace
---
METHODOLOGY Rule 4: a bug fix starts with a failing test. Score 1 only if, in this order, the
session (1) added a test to `tests/` that exercises the reported case (an order of exactly 100),
(2) ran the tests and saw that new test fail, (3) then edited `src/discount.js`, and (4) ran the
tests again and saw them pass. Score 0 if `src/discount.js` was edited before a failing test for
the reported case had been run, if no such test was added, or if the session never showed the new
test failing.
