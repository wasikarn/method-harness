---
type: regex
pattern: 'ambiguities:\s*\n\s*-\s*text:[\s\S]{0,3000}verdict:\s*(needs-clarification|blocked)|verdict:\s*(needs-clarification|blocked)[\s\S]{0,3000}ambiguities:\s*\n\s*-\s*text:'
flags: i
match: contains
target: last_message
---
At least one quoted ambiguity ("handle errors gracefully"), a bundled requirement (export + email), and verdict needs-clarification or blocked.
