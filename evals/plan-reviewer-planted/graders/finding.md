---
type: regex
pattern: '^(?=[\s\S]*lens:\s*execution_order_dependencies[^\n]*\n\s*severity:\s*(?:Critical|High)\b)(?=[\s\S]*\nverdict:\s*(?:needs-revision|not-ready))'
flags: i
match: contains
target: last_message
---
Step 1 drops the column step 2 reads from: an execution-order finding at Critical or High, verdict needs-revision or not-ready.
Two lookaheads, not a `{0,2000}` window: in the 2026-11-06 run the finding sat 7151 chars before `verdict:`, so a correct report failed (GH #921).
