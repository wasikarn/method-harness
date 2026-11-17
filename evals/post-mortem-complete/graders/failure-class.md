---
type: regex
pattern: 'weak_verification|missing_guardrail|missing_context|bad_tool_contract'
match: contains
target: last_message
---
Section 8 names one of the four Rule 3 failure classes (a refactor that changed behaviour with a test that only covered the second retry is weak_verification).
