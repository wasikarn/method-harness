---
type: regex
pattern: '(?:batch|store)\.py:\d+'
flags: i
match: contains
target: last_message
---
Passes if the final reply cites the defect location as file:line ((batch|store).py:<line>). Fails if it gives no file:line for it.
