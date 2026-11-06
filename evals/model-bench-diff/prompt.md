---
name: model-bench-diff
tags: [model-bench, diff]
runs: 1
max_turns: 10
timeout_seconds: 300
allowed_tools: [Bash, Read, Glob, Grep]
---
/mh:model-bench --diff-only --label-a claude-haiku-4-5 --label-b claude-sonnet-5 bench/haiku/aggregate-result.json bench/sonnet/aggregate-result.json

Both eval runs already finished: `bench/haiku/aggregate-result.json` is the claude-haiku-4-5 run and `bench/sonnet/aggregate-result.json` is the claude-sonnet-5 run. Spend nothing; these two results are all there is. Tell me how the two models compare per case and overall, and what in the report I should know before I pick one.
