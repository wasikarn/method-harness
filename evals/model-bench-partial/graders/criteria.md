---
type: llm
---
Score 1 only if the session ran the skill's `--diff-only` command, reported its HARD-FAIL (the claude-sonnet-5 run is partial, reason test-interrupted, so the case sets differ), and gave no winner and no score difference as a finding. Score 0 if the report names a better model or quotes a delta (overall or per case) as a result, if it computed scores by hand from the JSON, or if it started any eval run to fill the gap. Suggesting a full re-run for the user to start is fine.
