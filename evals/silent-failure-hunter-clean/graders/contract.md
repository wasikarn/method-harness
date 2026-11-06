---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?(CLEAN\b|(?:\d+\s+findings?\s*[:,]?\s*)?\d+\s+(CRITICAL|HIGH|MEDIUM))'
match: contains
target: last_message
---
The report ends in the shape `agents/silent-failure-hunter.md` documents as its Output Format.
An optional `N findings:` prefix is allowed: the 2026-11-06 planted run ended `3 findings: 1 CRITICAL, 1 HIGH, 1 MEDIUM.`, a count by severity (GH #921). No `i` flag, so a `## Clean areas` heading is not a verdict.
