---
type: regex
pattern: '^(?=[\s\S]*2026-09-04)(?=[\s\S]*\bPloy\b)(?=[\s\S]*\bCSV\b)(?=[\s\S]*N\+1)(?=[\s\S]*\bTuesday\b)[\s\S]*test_retry_backoff[\s\S]*conftest\.py[\s\S]*2\.5s[\s\S]*PR #218[\s\S]*OPS-91'
match: contains
target: last_message
---
Every specific in the human draft survives (the date, Ploy, CSV, N+1 and Tuesday anywhere; the
rest in order); the control fails if the skill rounds any of them off.
