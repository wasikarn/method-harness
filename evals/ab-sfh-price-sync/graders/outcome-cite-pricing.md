---
type: regex
pattern: 'pricing\.ts:\d+'
flags: i
match: contains
target: last_message
---
Passes if the final reply cites the defect location as file:line (pricing.ts:<line>). Fails if it gives no file:line for it.
