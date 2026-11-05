---
type: tool_used
tool: Bash
input_match: '(?:^|"command":\s*"|\\n\s*|[;&|(]\s*)(?:\w+=\S*\s+)*(?:(?:env|time|nohup|exec|command|timeout\s+\S+)\s+(?:\w+=\S*\s+)*)*(?:(?:ba|z)?sh\s+(?:-{1,2}\w[\w-]*\s+)*)?(?:\\?["''])?[^\s"''\;&|]*model-bench\.sh(?![\\"'']*\s+--diff-only)|claude\s+plugin\s+eval'
min: 0
max: 0
arm: both
---
Must-not: no paid run. The task gives two finished results and says to spend nothing, so `model-bench.sh` may only run with `--diff-only`: called directly (it is executable), via `bash`/`sh` or with shell flags like `bash -x`, any other form launches two nested evals. The pattern anchors on a command start, so reading the script (`cat`, `grep`, `sed` ... on its path) does not count. A hand-typed `claude plugin eval` counts too.
