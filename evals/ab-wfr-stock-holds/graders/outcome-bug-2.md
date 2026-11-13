---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `Reserve` in `internal/reserve/service.go` takes units from one warehouse after another with `TakeUpTo` and, when the warehouses together still do not have enough (`need > 0`), returns `ErrInsufficient` without putting back the units it already took, so those units vanish from sale with no reservation holding them (stock leaks on every failed split request; items show out of stock and are never sold or reclaimed, since the sweeper only restocks real reservations). Any wording counts as long as it says units already taken are not returned on the insufficient-stock path. Score 0 if the reply does not mention this, or only talks about a negative or zero quantity (that is a different defect).
