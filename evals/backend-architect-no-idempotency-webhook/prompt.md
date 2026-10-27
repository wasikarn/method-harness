---
name: backend-architect-no-idempotency-webhook
tags: [backend-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Here's our Stripe webhook handler (`src/webhooks/payment_webhook.py`) and some notes on Stripe's
redelivery behavior (`docs/stripe-webhook-notes.md`). Review the handler's reliability before we
turn on Stripe's webhook retries in production. Use the `mh:backend-architect` skill for this (Skill tool, `skill: "mh:backend-architect"`). Relay whatever it
produces back to me in full, verbatim.
