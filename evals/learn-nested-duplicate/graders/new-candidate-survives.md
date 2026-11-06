---
type: regex
pattern: '\blint(?:er|ing)?\b[^\n]{0,250}\b(new|propos|candidate|approv|worth saving)|\b(worth saving|new|propos|candidate|approv)[^\n]{0,250}(?:\n[^\n]{0,250})?\blint(?:er|ing)?\b'
flags: i
match: contains
target: last_message
---
The linter-before-commit rule is genuinely new (not in the store) and durable, so it should still
reach the gate. A session that suppresses everything just because a sub-index exists has
over-corrected, not deduped correctly. A regex on the reply, not `tool_used: AskUserQuestion`:
`claude -p` has no `AskUserQuestion`, so the skill hands the gate payload back in its final message
(GH #921). Either word order counts: the 2026-11-06 re-run wrote "needs your approval:" before
the rule. Only words that mean "this is new" count, not
saved/kept: "Already saved, skipping:\n- the linter rule" is the over-dedupe this grader catches.
After the word the window crosses at most one line break, since both 2026-11-06 follow-up replies
put the rule on the line after a "Worth saving (1):" / "New candidate (1):" heading. Known limit:
"the lint rule is not new" and "Nothing new.\n- the linter rule" also match.
