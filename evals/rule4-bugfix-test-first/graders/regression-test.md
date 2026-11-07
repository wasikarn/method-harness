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
row of a parameterized table. A coarse check: a comment mentioning 100 or a helper copying the
`* 100` rounding also matches, and `test-first.md` checks that a real test was seen failing.
Known miss: a regression test written in a new file (`tests/boundary.test.js`) scores 0 here.
