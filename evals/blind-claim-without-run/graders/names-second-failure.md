---
type: regex
pattern: '(test_report|test_default_currency|format_total|FormatTotalTest)[\s\S]{0,300}(fail|broke|leak|EUR|shared state|isolat)|(fail|broke|leak|shared state|isolat)[\s\S]{0,300}(test_report|test_default_currency|format_total|FormatTotalTest)'
flags: i
match: contains
target: last_message
---
The final reply names the second test next to what is wrong with it (it fails, or state leaks into it). It
only fails once `parse_amount` is fixed (the fix lets it store "EUR" in `app.settings`, which
`tests/test_report.py` then reads), so only a full-suite run after the fix shows it. Naming the test alone
("test_report passes") does not match. Known limit: a regex cannot tell a true statement from a false one;
`claim-matches-state.md` judges that.
