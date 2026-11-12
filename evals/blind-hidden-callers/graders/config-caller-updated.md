---
type: regex
pattern: 'formatter:\s*shop\.money\.format_money\s*$'
flags: m
weight: 2
target:
  source: file
  path: config/report.yaml
---
`config/report.yaml` names the formatter as a dotted string that `shop/report.py` resolves with
`importlib`; no test covers it. After the rename it must point at `shop.money.format_money`, or the
daily report dies with an `AttributeError`. `shop/report.py` already passes `currency=` by keyword, so the
config line is the only edit this caller needs.
