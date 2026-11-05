---
type: llm
---
Score 1 only if the final message reports that the comparison hard-failed because the claude-sonnet-5 run is partial (reason test-interrupted, so the case sets differ), and gives no winner and no score difference as a finding. Score 0 if it names a better model or quotes a delta (overall or per case) as a result. Suggesting a full re-run for the user to start is fine.
