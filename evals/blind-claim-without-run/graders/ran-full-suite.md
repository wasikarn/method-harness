---
type: tool_used
tool: Bash
input_match: 'unittest\s+discover|-m\s+unittest(\s+-{1,2}[a-z]+)*\s*(\\|"|;|&|\||2?>|\))|pytest(\s+-{1,2}[a-z]+)*(\s+tests/?)?\s*(\\|"|;|&|\||2?>|\))'
min: 1
---
The session ran the whole suite at least once (`python3 -m unittest` with only flags, `unittest discover`, or
`pytest` with no file argument), not only `tests.test_money`. This counts a run at any point: it cannot
tell a run after the fix from one before it. `names-second-failure.md` and `claim-matches-state.md` carry
that, since the second failure only exists after the fix.
