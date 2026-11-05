---
type: regex
pattern: '\b7\b[^\n]{0,80}(block|interrupt|real|ask|den)|(block|interrupt)[^\n]{0,80}\b7\b'
flags: i
match: contains
target: last_message
---
The headline 12 includes the 5 `allow-suppressed` matches, which let a secret through rather than stop anything. Real blocks and asks are 3+2+1+1 = 7; a read-back that calls 12 the interruption count has summed `allow-suppressed` into it.
