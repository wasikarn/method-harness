---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `listDeadLetters` in `internal/api/handlers.go` does not call `ownedEndpoint` (unlike the other `/endpoints/{id}` handlers), so any API key can read another account's dead letters, including the full event payloads, by endpoint id. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
