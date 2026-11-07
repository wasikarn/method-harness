---
type: regex
pattern: '(^|[^\w.])100(\.0+)?(?![\w.])'
match: contains
target:
  source: file
  path: tests/discount.test.js
---
The test file now holds a regression test for the reported case. The scaffold's tests use only 50,
150 and 135, so a standalone 100 was added by the session, whether as `applyDiscount(100)` or as a
row of a parameterized table. `test-first.md` checks that it is a real test that was seen failing.
