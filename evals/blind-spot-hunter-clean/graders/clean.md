---
type: regex
pattern: '(^|\n)[\s*_`#-]*(?:[Vv]erdict[\s*_:`]*)?CLEAN\b'
match: contains
target: last_message
---
Units are consistent end to end (cents everywhere, named in every signature); the verdict must be `CLEAN`.
`CLEAN (N dormant: ...)` passes too: since GH #921 a finding with `reachable-now?: no` keeps its
full entry but does not block CLEAN, and all three 2026-11-06 runs found only dormant edges here.
