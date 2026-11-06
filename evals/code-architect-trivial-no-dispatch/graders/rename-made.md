---
type: regex
pattern: 'def greet\(user\):\n\s+return f"Hello, \{user\}!"'
match: contains
target: {source: file, path: src/greeting.py}
---
The rename is actually made, in both the signature and the f-string, without loading an
architecture skill or agent first (`no-agent-dispatch.md`). A file check, not `tool_used: Edit`:
on a 2-line file both arms rewrite it with Write, so an Edit count failed every run in both arms
(kept trace, 2026-11-06, GH #921). `rename-correct.md` checks that no `usr` is left; this one also
fails an emptied or deleted file, which that `not_contains` check would pass.
