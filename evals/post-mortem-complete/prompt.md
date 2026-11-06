---
name: post-mortem-complete
tags: [post-mortem, clean]
runs: 1
max_turns: 16
timeout_seconds: 600
allowed_tools: [Bash, Read, Glob, Grep]
---
/mh:post-mortem gh-77

All four inputs are in this repo; do not ask for them. Trigger: `python3 -m unittest tests/test_retry.py` fails at the parent of HEAD: `test_backoff_first_retry_waits_base` (first retry waited 1.0s, expected 0.5s) and `test_with_retry_sleeps_between_attempts_only` (waits [1.0, 2.0], expected [0.5, 1.0]). Mechanism: `backoff()` in `src/retry.py` used `2 ** attempt` on a 1-based attempt after the "simplify" refactor, so every wait doubled. Patch: HEAD on the default branch (`GITLOG.txt` lists the SHAs). Validation: both tests in `tests/test_retry.py` pass at HEAD, run locally, no CI. Nobody was paged; found by a developer reading a slow test log. Destination: print-only, no archiving, no tickets. Your final message is the step 4 checklist followed by the full post-mortem.
