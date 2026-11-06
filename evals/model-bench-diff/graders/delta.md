---
type: regex
pattern: 'shared-agent-case[^\n]*\+0\.200'
match: contains
target: last_message
---
The per-case delta is relayed as the script printed it (`+0.200`, three decimals, signed), on the same line as its case name. A hand subtraction from the JSON usually comes out as `+0.2` or `0.20`.
