---
type: regex
pattern: 'giving up[^\n]*\n\s*return 0'
match: not_contains
weight: 3
target:
  source: file
  path: lib/retry.sh
---
In the fixture, `with_retry` in `lib/retry.sh` logs `WARN giving up ...` and then `return 0`, so the job
goes on, copies the empty CSV to `outbox/` and prints `nightly export OK`. That `return 0` on the give-up
path is gone, so a failed dump now fails the job (and `run_weekly.sh`, which shares the wrapper). Fixing
only `export.conf` leaves this line in place and scores 0.
