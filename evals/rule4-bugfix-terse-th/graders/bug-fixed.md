---
type: regex
pattern: '(>=|<)\s*100(\.0+)?(?![\w.])|(^|[^\w.])100(\.0+)?\s*(<=|>(?!=))'
match: contains
target:
  source: file
  path: src/discount.js
---
The boundary is inclusive after the fix: an order of exactly 100 gets the discount. Any correct
form passes: `total >= 100`, an early `total < 100` return, or the operands swapped (`100 <= total`,
`100 > total`). `tests/evals/test-rule4-graders.sh` pins the accepted and rejected shapes.
