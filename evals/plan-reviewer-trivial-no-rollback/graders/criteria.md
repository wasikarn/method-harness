---
type: llm
---
Score 1 only if findings is an empty list and verdict is production-ready. A finding that the plan
lacks a rollback or mitigation path scores 0: a one-file variable rename that `git revert` fully
undoes has no rollback gap. Manufacturing any other finding (test coverage, naming, a feature flag)
also scores 0.
