---
type: regex
pattern: 'shares the judge(?:''s)? model family|judge may favou?r its own family'
match: contains
target: last_message
flags: i
---
The script's WARN line reaches the reader: the claude-sonnet-5 arm was scored by a sonnet judge, which may favor its own family. Only the script derives this from the label and `suite.judgeModel`; a hand read of the scores misses it.
