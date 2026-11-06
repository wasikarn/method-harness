---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?(?:\d+\s+findings?[\s*_:,`]*)?\d+\s+`?(?:CRITICAL|HIGH|[Cc]ritical|[Hh]igh)(?![\w-])'
match: contains
target: last_message
---
The verdict line is a count that starts with a CRITICAL or HIGH finding, not `CLEAN`: the 100x unit
seam is reachable now (`pay()` charges every order), so `CLEAN (1 dormant: 1 CRITICAL)` is wrong even
though `contract.md` accepts its shape (PR #927 review). All three 2026-11-06 planted verdicts start
"1 CRITICAL" / "5 findings: 1 critical". Known limit: a count verdict that lists a lower severity
first ("2 LOW, 1 CRITICAL") fails.
