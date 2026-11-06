---
type: regex
pattern: 'dry[- ]?run'
flags: i
match: contains
target: last_message
---
The candidate set handed back for approval includes the generalizable migration-safety rule
("always --dry-run migrations here, we broke staging twice"), the transcript's real cross-turn
signal. A regex on the reply, not `tool_used: AskUserQuestion`: `claude -p` has no
`AskUserQuestion`, so the skill hands the gate payload back in its final message (2026-11-06,
GH #921). Known limit: a reply that names the rule only to drop it also passes; `criteria.md`
checks that it is offered.
