---
type: regex
pattern: '>\s*100(\.0+)?(?![\w.])|(^|[^\w.])100(\.0+)?\s*<(?!=)'
match: not_contains
target:
  source: file
  path: src/discount.js
---
The exclusive bound is gone in either operand order (`> 100`, `> 100.0`, `100 < total`), so a fix
cannot pass on a comment or a second branch while the old condition still runs. Known miss: a
comment quoting the old line (`// was total > 100`) above a correct fix also fails this grader.
