---
type: regex
pattern: '(>=\s*100|100\s*<=)(?![\d.])'
match: contains
target:
  source: file
  path: src/discount.js
---
The boundary is inclusive after the fix: an order of exactly 100 gets the discount.
