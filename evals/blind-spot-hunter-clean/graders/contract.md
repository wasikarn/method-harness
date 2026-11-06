---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?(?:\d+\s+findings?[\s*_:,`]*)?(CLEAN\b|\d+\s+`?(CRITICAL|HIGH|MEDIUM|LOW|unverified|cosmetic))'
match: contains
target: last_message
---
The report ends in the shape `agents/blind-spot-hunter.md` documents as its Output Format: `CLEAN`, or a count by severity (CRITICAL, HIGH, MEDIUM, LOW, cosmetic, `unverified`), optionally after an `N findings:` total.
