---
type: llm
---
Score 1 only if the reply reports, as a real defect, that dead letters are not persisted: the `snapshot` type and `persistLocked` in `internal/store/store.go` write only endpoints and deliveries, and `Open` loads nothing into `deadLetters`, while `Store.DeadLetter` (`internal/store/dlq.go`) removes the delivery from the persisted queue. Every restart or deploy permanently loses all dead letters, the failed events the queue exists to keep. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
