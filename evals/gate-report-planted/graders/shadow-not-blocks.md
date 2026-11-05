---
type: regex
pattern: '(shadow|would_deny|would_ask)[^\n]{0,200}(not (a |real |actual )?(block|ask|den|interrupt)|aren.t (block|ask|den)|were allowed|was allowed|(call|command)s? (was|were|went|got) (allowed|through)|allowed (the|it|them|anyway)|did ?n[o.]t block|matched but allowed)'
flags: i
match: contains
target: last_message
---
The 3 `would_deny`/`would_ask` rows come from shadow rules that journal and allow. The read-back must say they did not block anything.
