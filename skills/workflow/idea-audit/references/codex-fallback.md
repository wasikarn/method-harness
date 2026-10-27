# idea-audit: Phase 2 Claude fallback mechanics

Load when a Phase 2 fallback trigger fires and the attacker falls back to `general-purpose`.

Pipe the fallback agent's raw final message to the same
`scripts/check-verdict.py`, then `check-citations.py`. The fallback keeps every tool including
`Bash` and has no sandbox: capture `git status --porcelain` before and after and treat any diff
as a violation. The brief states: *you write nothing; report findings only in your final message.*
