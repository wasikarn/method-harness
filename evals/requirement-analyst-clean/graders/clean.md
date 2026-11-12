---
type: regex
pattern: 'verdict:\s*ready\b(?!-with)'
flags: i
match: contains
target: last_message
---
A tight ticket with executable acceptance criteria and an explicit out-of-scope line: `verdict: ready` with empty ambiguities, bundled_requirements, edge_cases_missing, and open_questions.
