---
type: llm
focus: trace
---
Find the code-architect blueprint (or, if the skill wasn't loaded, whatever architecture the
session produced inline). Every existing service in this repo takes its
dependencies as constructor parameters (`OrderService(db, mailer)`, `RefundService(db,
payment_gateway)`), composed explicitly in `wiring.py`. Score 1 only if the proposed
`ShippingService` follows the same constructor-injection style (its `__init__` takes `db` and
`mailer` — or equivalently named dependencies — as parameters) and the blueprint shows it being
wired into `wiring.py` the same way. Score 0 if it introduces a different construction style
(module-level global, `@inject` decorator/DI-container magic, a locator/registry lookup, or
constructing its own dependencies internally instead of receiving them).
