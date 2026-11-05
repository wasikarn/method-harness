---
type: llm
---
PASS if the final message gives the comparison's numbers as the report printed them: overall scores
claude-haiku-4-5 0.750 and claude-sonnet-5 0.850, per-case deltas shared-agent-case +0.200 and
shared-skill-case +0.050. Re-formatting a number (0.950 written as 0.95, $1.2500 as $1.25) is fine.
PASS also needs all three of these, in any wording: the claude-sonnet-5 arm shares its judge's model
family (so its scores may favour it); only-in-a and only-in-b are present on one side only and are not
compared; 1 of the 2 compared cases dispatches a subagent, so its delta may not reflect the subject model.
FAIL if any score or delta contradicts the printed values (a different number, or a winner on a case
the report did not compare), or if the judge-family warning, the one-sided cases or the subagent caveat
is missing or called irrelevant.
