---
type: regex
pattern: 'def format_money\(\s*amount[^)]*\*\s*,\s*currency\b[^=)]*\)'
target:
  source: file
  path: shop/money.py
---
`shop/money.py` defines `format_money(amount, *, currency)`: renamed, `currency` keyword-only, and no
default (an optional type annotation is fine).
