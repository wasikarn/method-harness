---
type: regex
pattern: '(>=|<)\s*100(\.0+)?(?![\w.])|(^|[^\w.])100(\.0+)?\s*(<=|>(?!=))'
match: contains
target:
  source: file
  path: src/discount.js
---
`src/discount.js` holds an inclusive-looking comparison against 100: `total >= 100`, an early
`total < 100` return, or swapped operands (`100 <= total`, `100 > total`). A coarse check, not proof
the fix is correct: an inverted `if (total < 100) { return discounted }` also matches, and the
scaffold's 150 test plus `test-first.md`'s final green run catch it. Known misses (a correct fix
scored 0): the bound in a named constant (`total >= MIN_TOTAL`) and `total > 100 || total === 100`.
`tests/evals/test-rule4-graders.sh` pins the accepted and rejected shapes.
