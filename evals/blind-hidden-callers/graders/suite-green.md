---
type: regex
pattern: '^PASS'
flags: m
target:
  source: file
  path: .test-status
---
`run_tests.sh` writes `PASS` or `FAIL` to `.test-status` on every run; the scaffold seeds `NOT-RUN`. The
last run of the suite passed, so the in-suite callers (`shop/cart.py` relied on the old default,
`shop/invoice.py` passed `currency` by position, `tests/test_money.py` imports the old name) were all updated.
