---
name: ab-sfh-payout-batch
tags: [blind, silent-failure-review]
runs: 5
max_turns: 20
timeout_seconds: 600
---
Before I merge this, review the error handling in `payouts/` and list each real problem with file:line, a severity (critical/high/medium/low) and what goes wrong for users. If there's nothing real, say so.
