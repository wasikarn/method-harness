---
type: regex
pattern: '\b\d{1,3}\s*/\s*100\b|\b\d{1,3}\s*%\s*(compliant|conform|complete)\b'
match: not_contains
target: last_message
---
Compliance is a per-requirement checklist, not a graded quality signal (Rule 5) — the report
must not reduce the two requirements to a single blended percentage.
