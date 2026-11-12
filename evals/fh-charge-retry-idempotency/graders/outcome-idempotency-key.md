---
type: regex
target: { source: file, path: payments/client.py }
flags: i
pattern: 'Idempotency-Key'
---
The gateway contract (`docs/gateway-api.md`) says a timed-out charge may still have been created,
and offers an `Idempotency-Key` header that makes a repeated POST return the first result. A
retry loop around `/charges` without that header charges the customer again every time the first
attempt timed out after the gateway took the money. The scaffold's `payments/client.py` never
mentions the header, so a match comes from the subject's change. `check.py` beside this case is
the executable form: a gateway that books the charge then times out must end with one charge.
