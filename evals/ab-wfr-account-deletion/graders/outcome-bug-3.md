---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `purge_due` in `accounts/deletion.py` selects accounts with `deletion_requested_at >= cutoff` (cutoff = now minus the grace days) instead of `<=`, so it deletes accounts that asked for deletion within the last 14 days, at the next hourly run with no grace period and no chance to cancel, and never deletes accounts whose grace period is actually over. Any wording counts as long as it names the inverted date comparison and the consequence (accounts purged early / immediately, or due accounts never purged). Score 0 if the reply does not mention this or calls the comparison correct.
