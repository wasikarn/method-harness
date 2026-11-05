---
type: regex
pattern: 'hard[- ]?fail|no (?:valid |real |fair )?comparison|(?:not|n[o''’]t)\s+comparable|\b(?:in|un)comparable|can(?:not|[’'']t) (?:\w+ )?be (?:\w+ )?compared'
match: contains
target: last_message
flags: i
---
One side is `partial: true`, so the script prints HARD-FAIL and no score table. The report must say the two runs cannot be compared, not pick a winner.
