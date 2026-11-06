---
type: tool_used
tool: Bash
input_match: 'audit\.sh'
min: 2
arm: with-only
---
The audit script ran at least twice: once to find the CRITs and once after the fixes. Editing a file without re-running is the skill's first named failure mode. The prompt asks for one run per Bash call, so a count of 2 stands in for order; `criteria.md` checks the order itself.
