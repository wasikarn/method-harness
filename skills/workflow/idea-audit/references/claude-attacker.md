# idea-audit: Phase 2 Claude attacker mechanics

Load before dispatching Phase 2's `general-purpose` attacker, the default (and the one a failed
Codex run goes back to).

Pipe the agent's raw final message to the same
`scripts/check-verdict.py`, then `check-citations.py`. The agent keeps every tool including
`Bash` and has no sandbox: capture `git status --porcelain` before and after and treat any diff
as a violation. The brief states: *you write nothing; report findings only in your final message.*
