---
type: regex
pattern: 'Final Verdict\**:'
match: contains
target: last_message
flags: i
---
Sanity check that the report actually completed and produced a Final Verdict line.
The colon is required: a refusal that says "I can't produce the Final Verdict line" matched the
bare phrase and scored 1.0 (2026-11-06, GH #921).
