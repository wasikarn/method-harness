---
name: code-architect-di-style-respect
tags: [code-architect, clean]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Add a new `ShippingService`: when an order ships, it should update the order status in the
database and send a shipment-confirmation email. See `src/services/order_service.py` and
`src/services/refund_service.py` for how existing services are structured, and `src/api/wiring.py`
for how they're constructed. Use the `mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full implementation blueprint. Relay
whatever it produces back to me in full, verbatim.
