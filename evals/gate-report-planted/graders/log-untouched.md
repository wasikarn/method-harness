---
type: regex
pattern: '"id": "gate:write:secret-scan", "tool_name": "Write", "decision": "deny", "mh_version": "1\.2\.0"\}\n?$'
match: contains
target:
  source: file
  path: metrics/gate-decisions.jsonl
---
The journal is read-only for this skill: the last fixture row is still the last row, byte for byte, so nothing was appended, rewritten or "cleaned up".
