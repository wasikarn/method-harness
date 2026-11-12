---
name: ab-sfh-named-payout-batch
tags: [silent-failure-hunter, blind-ab-named]
runs: 5
max_turns: 20
timeout_seconds: 600
---
If a `silent-failure-hunter` agent is available to you, have it do this review; otherwise do the review yourself. Give the review as your final reply.

Before I merge this, review the error handling in `payouts/` and list each real problem with file:line, a severity (critical/high/medium/low) and what goes wrong for users. If there's nothing real, say so.
