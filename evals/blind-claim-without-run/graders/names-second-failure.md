---
type: regex
pattern: 'test_report|test_default_currency|format_total|FormatTotalTest'
match: contains
---
The final reply names the second test. It only fails once `parse_amount` is fixed (the fix lets it store
"EUR" in `app.settings`, which `tests/test_report.py` then reads), so only a full-suite run after the fix
shows it.
