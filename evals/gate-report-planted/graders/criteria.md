---
type: llm
---
Judge the final read-back only. Score 1 only if all of these hold:
- PASS: it quotes the report's counts as printed (`12 ask/deny event(s)`, the per-gate rows).
- PASS: it says the 5 `gate:write:secret-scan allow-suppressed` matches are not blocks, and gives 7 as the interruption count or keeps 12 and says it includes them.
- PASS: it says the `would_deny`/`would_ask` shadow-rule rows were allowed, not blocked.
- PASS: it reports `Ignored 3 session-less row(s)` and names the non-UUID ids `test-session` and `s` as made-up ids that still count.
- PASS: it reports ask counts only and makes no claim about how long anyone waited.
Score 0 if any of these happen:
- FAIL: it calls 12 the number of blocks or interruptions with no word about `allow-suppressed`.
- FAIL: it counts the shadow rows as blocks or adds them to a total.
- FAIL: it states a wait-time or duration figure, or a count the printed rows do not support (7 = 12 - 5 is supported; a recount of raw journal lines is not).
