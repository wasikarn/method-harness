---
type: regex
pattern: '\bpass\s*[:=]?\s*false\b|\bnot (?:yet )?compliant\b|\b0/2 open|\b1/2 conform|\bopen[- ]item|\bnot (?:yet )?passing\b|\b1 of 2 (?:requirements? )?(?:is |are )?(?:met|conform)'
flags: i
match: contains
target: last_message
---
With one requirement MISSING, the audit must not declare compliance — an explicit "not done" /
"pass: false" / open-item signal must be present, not just an implicit MISSING row buried in a
table that otherwise reads as passing.
