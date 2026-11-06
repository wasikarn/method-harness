---
name: blind-spot-hunter-clean
tags: [blind-spot-hunter, clean]
runs: 1
max_turns: 12
timeout_seconds: 600
---
Use the `mh:blind-spot-hunter` agent (Agent tool, `subagent_type: "mh:blind-spot-hunter"`) to hunt for cross-file blind spots in `shop/models.py`, `shop/pricing.py`, `shop/payments.py`, and `shop/gateway.py`, which a per-file review already passed.
The files are in the current working directory: `shop/models.py`, `shop/pricing.py`, `shop/payments.py`, `shop/gateway.py`.

Return the agent's report verbatim as your final message. Add nothing before or after it.
