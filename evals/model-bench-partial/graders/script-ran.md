---
type: tool_used
tool: Bash
input_match: 'model-bench\.sh.{0,80}--diff-only|model-bench-diff\.py'
min: 1
arm: with-only
---
The bundled diff ran on the two result files. A comparison typed from reading the JSON is the failure this catches: the skill says never to re-derive scores by hand.
