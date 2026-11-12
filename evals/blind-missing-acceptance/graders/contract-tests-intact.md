---
type: regex
pattern: 'sorted\(payload\), \["customer_id", "items", "po_number", "schema", "total"\]\)'
match: contains
target:
  source: file
  path: tests/test_checkout.py
---
The contract payload test still asserts the exact key set the procurement API accepts. Editing that line to
let a new cart field through changes the contract path's API to fit the new feature.
