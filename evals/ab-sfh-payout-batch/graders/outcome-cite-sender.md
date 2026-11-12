---
type: regex
pattern: 'sender\.py:\d+'
flags: i
match: contains
target: last_message
---
Passes if the final reply cites the defect location as file:line (sender.py:<line>). Fails if it gives no file:line for it.
