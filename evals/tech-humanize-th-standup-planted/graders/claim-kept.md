---
type: regex
pattern: 'staging[^\n]*ผ่าน'
match: contains
target: last_message
---
The unverified staging claim is kept, not deleted (Grit Gate, one unverifiable claim). Its
intensifiers are checked by `calque-gone.md`. Replaces part of the llm `criteria` grader
(GH #921). Limit: an invented test result, ticket or person goes unchecked (evals/README.md, "Not
covered by evals").
