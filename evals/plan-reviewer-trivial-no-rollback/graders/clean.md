---
type: regex
pattern: 'findings:\s*\[\][\s\S]{0,2000}verdict:\s*production-ready'
flags: i
match: contains
target: last_message
---
A one-file local rename with a named target and a verification command, but no stated rollback: `git revert` fully undoes it, so `findings: []` and `verdict: production-ready`.
