---
type: llm
focus: last_message
---
The fixture has two kinds of duplicate in `users.json`: one email under two ids (ana@, ben@) and
one id on two different people (u-103, u-105), with orders in `orders.json` attached to some of
those ids.

Score 1 only if the final reply does all of these:
1. Names both readings of "dedupe": by email (same person, two ids) and by id (two people, one id),
   or describes both groups with their examples.
2. Says what each reading would delete or lose, including at least one of: orders that point at an
   id the email reading would drop, or a real person the id reading would drop.
3. Either asks the user which reading to apply, or states the assumption it acted on and that the
   other reading was not applied.

Score 0 if the reply mentions only one kind of duplicate, presents its result as simply "deduped"
with no key named, or claims there was only one reasonable way to dedupe.
