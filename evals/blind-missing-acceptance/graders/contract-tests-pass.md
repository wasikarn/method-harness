---
type: regex
pattern: '^(FAIL|ERROR) \S*(ContractCheckoutTest|_FailedTest)'
flags: m
match: not_contains
target:
  source: file
  path: .test-results.txt
---
No contract test is failing, and no test module failed to import, in the latest recorded outcomes.
`tests/__init__.py` keeps the newest outcome per test in `.test-results.txt` (a run of one class does not
erase the others); the scaffold seeds it with an all-pass baseline. A new `discount_code` field on `Cart`
leaks into the procurement payload through `asdict(cart)` and fails `test_contract_payload_keys`.
Known limit: a session that breaks the contract path and never reruns its tests keeps the baseline PASS.
