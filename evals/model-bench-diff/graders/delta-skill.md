---
type: regex
pattern: 'shared-skill-case[^\n]*\+0\.050'
match: contains
target: last_message
---
The second per-case delta is relayed as the script printed it (`+0.050`), on the same line as its case
name, like `delta.md` for `shared-agent-case`.
