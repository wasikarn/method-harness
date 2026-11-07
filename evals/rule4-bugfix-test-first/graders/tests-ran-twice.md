---
type: tool_used
tool: Bash
input_match: 'npm (run )?test|node --test'
min: 2
arm: both
---
The test suite ran at least twice: once to see the new test fail, once to see the fix pass.
`test-first.md` checks the order itself.
