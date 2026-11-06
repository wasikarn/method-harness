---
type: regex
pattern: '^(?=[\s\S]*PR #412)(?=[\s\S]*flags/rollout\.py)(?=[\s\S]*\b5%)(?=[\s\S]*2026-08-30)(?=[\s\S]*\b3%)(?=[\s\S]*0\.4%)'
match: contains
target: last_message
---
Every specific survives, in any order: PR #412, `flags/rollout.py`, the 5% gate, 2026-08-30, 3%
and 0.4%. Replaces the presence half of the llm `criteria` grader (GH #921); presence checks belong
in a regex. Limit: a changed number next to the right ones (say an extra "4%") is not caught.
