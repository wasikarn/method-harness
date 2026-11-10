---
type: tool_used
tool: Bash
input_match: 'diff\s+(?:\S+\s+)*--(?:cached|staged)'
min: 1
arm: both
---
Rule 13 asks to check `git diff --cached --name-only` after staging. At least one Bash call looks at the
staged set with `diff --cached` or `--staged` before the commit lands, whichever way `git` is spelled (`git`, `$G`,
`/opt/homebrew/bin/git`: the sandbox breaks plain `git`, so runs use the last two). `git status` alone does
not count: it lists the working tree too. A `diff --cached` run before anything is staged also matches, so
this grader proves only that a check was made; `committed-only-two.md` checks that it came after staging.
