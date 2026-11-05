---
type: regex
pattern: '(shadow|would_(deny|ask|\*))[^\n]{0,200}(not (a |real |actual )?(block|ask|den|interrupt)|aren.t (block|ask|den)|were allowed|was allowed|(call|command)s? (was|were|went|got) (allowed|through)|allowed (the|it|them|anyway)|did\s?n[o.''’]t (block|stop)|matched but allowed|nothing (was |got )?(blocked|stopped)|(commands?|calls?) (still )?ran\b(?!\s+into)|never (block|stop|interrupt)|let[^\n]{0,20}(command|call)s?[^\n]{0,10}run)'
flags: i
match: contains
target: last_message
---
The 3 `would_deny`/`would_ask` rows come from shadow rules that journal and allow. The read-back must say they did not block anything.
