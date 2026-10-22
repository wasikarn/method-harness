---
type: regex
pattern: 'verdict:\s*(production-ready|ready-with-caveats|needs-revision|not-ready)'
flags: i
match: contains
target: last_message
---
The report ends in the shape `agents/plan-reviewer.md` documents as its Output Format.
