---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `cancelBooking` in `src/cancellation.ts` no longer rejects a booking that is already cancelled (the base version threw a 409 Conflict). Each repeated `DELETE /bookings/:id`, such as a retry or double click, refunds the booking again (money refunded twice or more) and re-runs the waitlist promotion, although `docs/api.md` still promises a 409. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
