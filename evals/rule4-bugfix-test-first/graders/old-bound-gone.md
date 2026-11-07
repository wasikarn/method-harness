---
type: regex
pattern: '>\s*100(?![\d.])'
match: not_contains
target:
  source: file
  path: src/discount.js
---
The exclusive `> 100` check is gone, so a fix cannot pass on a comment or a second branch while
the old condition still runs.
