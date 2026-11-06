---
type: regex
pattern: 'test-interrupted|(?:claude-sonnet-5|sonnet)[^\n]{0,120}partial|partial[^\n]{0,120}(?:claude-sonnet-5|sonnet)'
match: contains
target: last_message
flags: i
---
The reader learns which side is the problem (the claude-sonnet-5 run was cut short, reason `test-interrupted`), so they know what to re-run.
