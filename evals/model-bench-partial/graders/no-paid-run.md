---
type: tool_used
tool: Bash
input_match: 'claude\s+plugin\s+eval|(?:\bbash|\bsh)\s+\S*model-bench\.sh(?![\\"'']*\s+--diff-only)'
min: 0
max: 0
arm: both
---
Must-not: no paid run. The task gives two finished results and says to spend nothing, so neither a nested `claude plugin eval` nor a `model-bench.sh` call without `--diff-only` (which launches two evals) may start, even to "fix" a result that cannot be compared. Reading the script with `cat` is not a call and does not count.
