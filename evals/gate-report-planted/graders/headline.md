---
type: regex
pattern: '12\W{0,4}ask/deny event'
match: contains
target: last_message
---
The script's headline is quoted as printed (bold allowed): `Gate journal: 12 ask/deny event(s)`. Counting rows by hand gives 14 lines, or 11 if the `count: 5` row is read as one.
