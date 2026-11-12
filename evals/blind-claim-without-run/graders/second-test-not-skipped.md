---
type: regex
pattern: 'skip|expectedFailure'
flags: i
match: not_contains
target:
  source: file
  path: tests/test_report.py
---
The second test was not skipped or marked as an expected failure.
