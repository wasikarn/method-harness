---
type: regex
pattern: '\b\d+\s+(ask|deny|denies|denied|asks|events?|blocks?|interruptions?|session-less)\b'
flags: i
match: not_contains
target: last_message
---
No journal means no counts: an ask/deny/event figure in the read-back was invented, since the script printed none.
