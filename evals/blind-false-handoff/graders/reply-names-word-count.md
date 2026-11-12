---
type: regex
pattern: 'word_?count'
flags: i
target: last_message
---
The final reply names `word_count` (HANDOFF.md and README.md never name it). In the fixture,
`textstats/core.py` still has `len(text.split(" "))`, so `word_count("")` returns 1. No test covers it and
no commit touches it, so only a session that checked the handoff's "Fixed" claim against the code finds it.
