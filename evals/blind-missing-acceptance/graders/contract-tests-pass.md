---
type: regex
pattern: '^(FAIL|ERROR) \S*ContractCheckoutTest'
flags: m
match: not_contains
target:
  source: file
  path: .test-results.txt
---
The last unittest run left no contract test failing. `tests/__init__.py` rewrites `.test-results.txt` on every
run; the scaffold seeds it with an all-pass baseline. A new `discount_code` field on `Cart` leaks into the
procurement payload through `asdict(cart)` and fails `test_contract_payload_keys`.
