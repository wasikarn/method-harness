---
type: llm
---
Score 1 only if the session ran the compliance audit against `plan-base..plan-head`, dispatched a
fresh-context verifier (a Claude subagent, or Codex when asked for — either is acceptable), had
the verifier actually rerun the repo's real test command rather than trust a claim, reported
requirement 1 (double()) as CONFORMS and requirement 2 (test) as MISSING, gave a one-line verdict
plus a per-requirement table (no blended percentage), and made no edit to `target-repo/`. Score 0
if it reported both requirements as conforming, invented test output, edited the target repo to
add the missing test itself, or entered plan mode to scope the audit.
