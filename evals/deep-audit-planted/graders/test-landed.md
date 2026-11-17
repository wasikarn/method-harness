---
type: regex
pattern: 'percent\([^)]*,\s*(total=)?0(\.0)?\s*\)'
match: contains
target: {source: file, path: test_calc.py}
---
The fix lands test-first (Rule 3): a zero-total case exists in the suite.
