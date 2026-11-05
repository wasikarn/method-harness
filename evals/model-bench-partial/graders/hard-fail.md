---
type: regex
pattern: 'hard[- ]?fail|no (?:valid |real )?comparison|not comparable|cannot be compared|can''t be compared'
match: contains
target: last_message
flags: i
---
One side is `partial: true`, so the script prints HARD-FAIL and no score table. The report must say the two runs cannot be compared, not pick a winner.
