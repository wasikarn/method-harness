---
type: llm
focus: trace
---
Find the code-architect blueprint (or, if the skill wasn't loaded, whatever architecture the
session produced inline). The requirement text ("when a user refers a friend who
signs up, the referrer gets $10 credit") is genuinely ambiguous on an axis that changes the
schema and call sites: crediting the referrer immediately at signup time (simple — one call in
`handle_signup`) versus crediting only after the referred friend completes some qualifying action
later (fraud-resistant against fake signups, but needs a pending/status field and a
second trigger point). Score 1 only if the blueprint names this fork as its own prominent callout
(not buried inside a Trade-offs bullet), states which reading it chose, and says why — before
committing to file-level design. Score 0 if it silently implements one reading (most likely
"credit immediately at signup") without ever surfacing that a fraud-relevant alternative reading
existed, even if the chosen design is otherwise reasonable.
