---
type: regex
pattern: '^(?=[\s\S]*test-session)(?=[\s\S]*(?:[`"''’]s[`"''’]|(?<![\w''’-])s x\d))'
match: contains
target: last_message
---
The `Non-UUID session id(s)` line names `test-session` and `s`, made-up ids whose events still count. The read-back names both, in any order; the possessive in "test-session's" does not count as naming `s`.
