---
type: regex
pattern: 'applyDiscount\(\s*100(\.0+)?\s*\)'
match: contains
target:
  source: file
  path: tests/discount.test.js
---
The test file now holds a regression test for the reported case. The scaffold's tests use only 50
and 150, so a call with 100 was added by the session.
