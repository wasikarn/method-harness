---
type: regex
pattern: '(allow-suppressed|suppressed)[^\n]{0,200}(not (a |real )?blocks?|isn.t a block|aren.t blocks|let [^\n]{0,40}through|includ)|includ[^\n]{0,120}suppressed|\b(7|seven)\b[^\n]{0,80}(block|interrupt|real|ask|den)|(block|interrupt|stop|ask|den)[^\n]{0,80}\b(7|seven)\b'
flags: i
match: contains
target: last_message
---
The headline 12 includes the 5 `allow-suppressed` matches, which let a secret through rather than stop anything (SKILL.md: keep them out of an interruptions total, or say so). The read-back either gives 7 (3+2+1+1) as the block count or says the 12 includes the suppressed matches; "Gates blocked work 12 times" with neither fails.
