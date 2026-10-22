---
type: tool_used
tool: Agent
min: 6
max: 6
---
Agent calls per run: 6 on the default critic path (5 Diverge + 1 critic). The opt-in host path (8 calls) is out of this case's scope. Fewer means branches were simulated in one context; more means a nested spawn or a retry. This counts calls only; it cannot see wave shape or peak concurrency.
