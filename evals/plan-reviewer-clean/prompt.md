---
name: plan-reviewer-clean
tags: [plan-reviewer, clean]
runs: 1
max_turns: 12
timeout_seconds: 600
---
Use the `mh:plan-reviewer` agent (Agent tool, `subagent_type: "mh:plan-reviewer"`) to review the implementation plan in `plan.md` before anyone builds it.
The files are in the current working directory: `plan.md`, `src/worker.py`, `tests/test_worker.py`.

Return the agent's report verbatim as your final message. Add nothing before or after it.
