---
type: regex
pattern: 'zzz scratch row'
match: not_contains
target:
  source: file
  path: dev/customers.json
---
The two leftover scratch rows are gone, so the database really is clean and not merely reported as clean.
