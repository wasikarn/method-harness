---
type: regex
pattern: '"skills":\s*\[[^\]]*"mh:gate-report"'
match: contains
target: trace
arm: with-only
---
The plugin loaded `mh:gate-report`: the trace's `system`/`init` event lists it under `skills`. The prompt
invokes it by slash command, which the eval child expands (its own transcript shows
`<command-name>/mh:gate-report</command-name>` and the skill text), but `trace.jsonl` omits that
expanded user turn, so a regex on the skill's own text never matches (confirmed 2026-11-06).
