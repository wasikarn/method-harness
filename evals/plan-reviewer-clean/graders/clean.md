---
type: regex
pattern: '^(?=[\s\S]*findings:\s*\[\])(?=[\s\S]*\nverdict:\s*production-ready)'
flags: i
match: contains
target: last_message
---
A small, complete plan with a named target, a verification command, and a rollback: `findings: []` and `verdict: production-ready`.
Two lookaheads, not a `{0,2000}` window: with a real repo to check, `cleared_decoys` can put the verdict far after `findings:` (GH #921).
