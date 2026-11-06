---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?(?:\d+\s+findings?[\s*_:,`]*)?(CLEAN\b|\d+\s+`?(CRITICAL|HIGH|MEDIUM|LOW|[Cc]ritical|[Hh]igh|[Mm]edium|[Ll]ow|[Uu]nverified|[Cc]osmetic)(?![\w-]))'
match: contains
target: last_message
---
The report ends in the shape `agents/blind-spot-hunter.md` documents as its Output Format: `CLEAN`, or a count by severity (CRITICAL, HIGH, MEDIUM, LOW, cosmetic, `unverified`), optionally after an `N findings:` total.
Severity words count in upper case or capitalised: a 2026-11-06 planted run ended "5 findings: 1
critical, 3 low, 1 unverified". The word must end there, so "2 low-risk" or "1 high-level" in prose
does not pass. `CLEAN` stays upper case, so a line starting "Clean" does not pass. Known limit:
"1 critical path" at the start of a line passes.
