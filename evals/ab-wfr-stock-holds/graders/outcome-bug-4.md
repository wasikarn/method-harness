---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `DELETE /carts/{cart}/reservations` (`releaseCart` in `internal/api/handlers.go`, calling `ReleaseCart` in `internal/reserve/service.go`) releases every hold of the cart named in the URL without checking that the caller's `X-Cart-ID` matches it, unlike `listCart` and `reserveCart`, and contrary to docs/api.md (other carts' holds must be refused with 403), so anyone can empty any other shopper's held items (cart ids are guessable or visible), and the shopper loses the items at checkout. Placing it at `releaseCart` or `ReleaseCart` both count. Score 0 if the reply does not mention this or calls the endpoint correct.
