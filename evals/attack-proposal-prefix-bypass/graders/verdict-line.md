---
type: regex
target: last_message
pattern: '[Vv]erdict\W{0,8}(?:NO-GO|GO|INCOMPLETE)\b'
---
The report carries step 6's verdict: GO, NO-GO or INCOMPLETE, after a `Verdict` label (plain,
bold, or as a heading).
