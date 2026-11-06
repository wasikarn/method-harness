---
type: regex
target: last_message
pattern: '[Vv][Ee][Rr][Dd][Ii][Cc][Tt](?:\W{0,8}|\s+[Ii][Ss]\s+\W{0,4})(?:NO-GO|GO|INCOMPLETE)\b'
---
The report carries step 6's verdict: GO, NO-GO or INCOMPLETE, after a `Verdict` label in any case
(plain, bold, as a heading, or "the verdict is NO-GO"). The verdict words stay upper-case so a
lowercase "go" in prose does not count.
