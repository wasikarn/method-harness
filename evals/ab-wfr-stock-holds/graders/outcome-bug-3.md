---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `cmd/stockd/main.go` builds the hold length as `time.Duration(cfg.HoldMinutes) * time.Second` although `HoldMinutes` is documented in minutes (`internal/config/config.go`, `hold_minutes` in `config.example.json`, docs/api.md), so holds last 15 seconds instead of 15 minutes: shoppers' held items run out almost at once, checkout (`Confirm`) fails with 410, and the sweeper puts the units back on sale while the shopper is still checking out. Any wording counts as long as it names the seconds-versus-minutes mix-up for the hold length and a user-facing consequence. Score 0 if the reply does not mention this, or only mentions `SweepSeconds` (which is converted correctly).
