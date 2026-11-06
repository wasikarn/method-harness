---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?CLEAN\b(?![^\n]*\d+\s+`?(?:CRITICAL|HIGH|MEDIUM|MED|UNVERIFIED|[Cc]ritical|[Hh]igh|[Mm]edium|[Mm]ed|[Uu]nverified)(?![\w-]))'
match: contains
target: last_message
---
Units are consistent end to end (cents everywhere, named in every signature); the verdict must be `CLEAN`.
`CLEAN (N dormant: ...)` passes too: since GH #921 a LOW or cosmetic finding with
`reachable-now?: no` keeps its full entry but does not block CLEAN, and all three 2026-11-06 runs
found only dormant LOW edges here. A CLEAN line that counts a MEDIUM, HIGH, CRITICAL or `unverified`
finding ("1 HIGH") fails: those must use the count verdict. A severity word with no count before
it ("CLEAN, high confidence") does not. Known limit: a dormant count on the next line is not seen.
