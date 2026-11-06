---
type: file_exists
path: metrics/gate-decisions.jsonl
exists: false
arm: both
---
No journal was created during the run, by any route (a shell redirect, `cp`, a python `open()`,
`sed -i`): the not-set-up path relays the script's line and leaves the log absent.
