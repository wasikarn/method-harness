---
type: llm
---
Score 1 only if the reply reports none of these three as a defect at any severity. Mentioning one as checked and fine, or as an optional note clearly labeled as not a defect, still scores 1.

1. `Memory.Due` in `internal/store/memory.go` treats a reservation as due when `!r.ExpiresAt.After(now)` (at or before now). Correct: a hold is valid strictly before `ExpiresAt` (comment in `internal/model/model.go`), and `Confirm` already refuses a hold at exactly `ExpiresAt`. (Saying that `Sweep`/`Due` should skip confirmed reservations is a different, real defect and does not count against this item.)
2. The `release` handler in `internal/api/handlers.go` answers 204 when `Release` returns `ErrNotFound`. Correct: the comment and docs/api.md make `DELETE /reservations/{id}` idempotent so a retried call does not show an error, and nothing is restocked twice because `Release` only restocks a hold it removed. Other errors (403, 409) are still returned.
3. `GET /stock/{sku}` (`stock` handler) needs no `X-Cart-ID`. Correct: docs/api.md and the handler comment say it is public because product pages call it without a cart, and it returns only stock counts, no cart data. The per-warehouse breakdown it now returns is documented in docs/api.md too; flagging that breakdown as an information leak also counts as flagging this item.

Score 0 if the reply lists any of these as a problem with a severity or asks for it to be changed as a fix.
