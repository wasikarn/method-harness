---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `promote` in `src/waitlist.ts` charges with the idempotency key `waitlist-${entry.slotId}`, the same key for every party promoted into one class. `PaymentGateway.charge` (`src/payments.ts`) returns the original charge for a repeated key and does not charge again, so the second and later parties promoted into a class get a confirmed booking without being charged (their booking carries the first party's charge id, so a later refund hits someone else's charge). Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
