---
type: regex
target: trace
pattern: 'jobs\.json[\s\S]{0,1000}\\*"email\\*"|\\*"email\\*"[\s\S]{0,1000}jobs\.json'
---
`scheduler.py` calls `send_report(**job["args"])` with the keys from `jobs.json`, so after the rename
those keys must say `email` or the nightly jobs raise TypeError. No test covers that path, so a run
that only greps `send_report(` and runs the tests misses it. The scaffold never contains the quoted
string `"email"`, so a match comes from the subject's own edit.

Score 1: the trace shows `jobs.json` being changed so its args use the `"email"` key (an Edit/Write
to `jobs.json`, or a sed/python command on it, within 1000 characters of the quoted `"email"`).

Score 0: `jobs.json` still passes `"recipient"`, i.e. no edit to it near a quoted `"email"` key.
