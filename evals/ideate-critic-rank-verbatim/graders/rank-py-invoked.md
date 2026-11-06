---
type: tool_used
tool: Bash
input_match: rank.py
min: 1
arm: with-only
---
The agent's own Procedure step 4 requires piping scores into `rank.py` via Bash rather than
computing totals/shortlist/runnerUp/nonObviousPick by hand.
