---
type: regex
pattern: '"skills":\s*\[[^\]]*"mh:model-bench"'
match: contains
target: trace
arm: with-only
---
Load check, not invocation proof: the trace's `system`/`init` event lists `mh:model-bench` under
`skills` whenever the plugin loaded. Why a slash-invoked skill can't be matched directly:
`evals/README.md`, the post-mortem paragraph.
