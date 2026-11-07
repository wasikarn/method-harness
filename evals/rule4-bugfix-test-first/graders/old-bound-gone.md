---
type: regex
pattern: '>\s*100(\.0+)?(?![\w.])'
match: not_contains
target:
  source: file
  path: src/discount.js
---
The exclusive `> 100` check (or `> 100.0`) is gone, so a fix cannot pass on a comment or a second
branch while the old condition still runs.
