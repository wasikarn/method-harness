---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?attack-proposal"'
min: 0
max: 0
arm: both
---
The fix is already built and committed: per `attack-proposal`'s own scope line, a diff that
already exists goes to `mh:deep-audit`, not to a skill that vets a
proposal before code exists.
