---
type: regex
pattern: 'test-session[^\n]{0,60}\bs\b'
match: contains
target: last_message
---
The `Non-UUID session id(s)` line names `test-session` and `s`, made-up ids whose events still count. The read-back names both.
