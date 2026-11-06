---
type: regex
pattern: '3 session-less'
flags: i
match: contains
target: last_message
---
Two `"session_id": null` rows and one row with no `session_id` key are left out; the script prints `Ignored 3 session-less row(s)` and the read-back reports that count.
