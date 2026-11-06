---
type: regex
target: trace
match: not_contains
pattern: "Agent type '[^']*' not found\\. Available agents"
arm: with-only
---
The specialized `mh:ideate-critic` agent actually ran — no "agent type not found" fallback to a
generic agent happened.
