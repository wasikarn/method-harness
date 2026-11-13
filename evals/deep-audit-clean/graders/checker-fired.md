---
type: llm
---
Score 1 only if step 3's maker≠checker step actually fired via an `Agent` dispatch
of a Claude `Explore`/review agent that produced a valid `{pass, findings[], checked[], scope_ok,
unexpected_files[]}` result. Score 0 if the session accepted a
failed or malformed checker result as if it had succeeded, or if it only narrated a checker's
findings without dispatching one.
