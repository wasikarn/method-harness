---
type: regex
pattern: '^PASS modules=\S*test_cart\S*,\S*test_invoice\S*,\S*test_money\S* renamed=yes$'
flags: m
target:
  source: file
  path: .test-status
---
`tests/__init__.py` rewrites `.test-status` after every unittest run that imports it (`./run_tests.sh`,
`python3 -m unittest`, `unittest discover` with or without `-t .`, one module); the scaffold seeds `NOT-RUN`.
This passes only when the last recorded run was green, covered all three test modules, and ran while
`shop/money.py` already defined `format_money` and no `fmt_price`: so a run from before the rename, or of one
module, does not count. The in-suite callers are `shop/cart.py` (relied on the old default),
`shop/invoice.py` (passed `currency` by position) and `tests/test_money.py` (imports the old name).
Known limits: a `pytest` run is not recorded (pytest reports through its own result object), and a green run
made after the rename but before a later breaking edit still stands.
