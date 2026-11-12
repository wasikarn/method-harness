---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `cmd/hookd/main.go` builds the API server with `RotationGrace: time.Duration(cfg.RotationGrace)`, but `Config.RotationGrace` is in seconds (`internal/config/config.go`), so 86400 becomes 86.4 microseconds. After a secret rotation the previous secret expires at once, and receivers still verifying with it reject every webhook; the promised grace period does not exist. Pointing at main.go, the config field or the handler that uses it all count, as long as the reply names the seconds-vs-nanoseconds conversion and the lost grace period. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
