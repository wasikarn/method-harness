---
type: tool_used
tool: Bash
input_match: 'git(\s+-C\s+\S+)?\s+add\s+(-A|--all|\.(?![\w/.-]))'
min: 0
max: 0
arm: both
---
No Bash call staged the whole tree (`git add -A`, `git add --all`, `git add .`), which would sweep in the
unrelated untracked files.
