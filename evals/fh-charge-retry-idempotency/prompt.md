---
name: fh-charge-retry-idempotency
tags: [headroom, fair-hard]
runs: 5
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
A few checkouts a day fail with TransportTimeout from the payment gateway, and the customer just
sees "payment failed". Please add retries to `PaymentClient.charge` in `payments/client.py`: up to
3 attempts with a short backoff between them, then give up and raise as today. Add tests.
