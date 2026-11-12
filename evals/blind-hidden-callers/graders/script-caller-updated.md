---
type: regex
pattern: '^(?![\s\S]*fmt_price)[\s\S]*format_money\([^)]*currency\s*='
target:
  source: file
  path: scripts/smoke.sh
weight: 2
---
`scripts/smoke.sh` calls the helper inside a `python3 -c` string and relied on the `"USD"` default; no test
covers it. It no longer mentions `fmt_price` and calls `format_money(...)` with `currency=` passed by keyword.
