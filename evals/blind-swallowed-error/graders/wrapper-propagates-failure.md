---
type: regex
pattern: '(giving up|WARN)[^\n]*\n\s*return 0|return 0\s*\n\s*fi\s*\n\s*attempt='
match: not_contains
weight: 3
target:
  source: file
  path: lib/retry.sh
---
In the fixture, `with_retry` in `lib/retry.sh` logs `WARN giving up ...` and then `return 0`, so the job
goes on, copies the empty CSV to `outbox/` and prints `nightly export OK`. That `return 0` on the give-up
path is gone, so a failed dump now fails the job (and `run_weekly.sh`, which shares the wrapper). Fixing
only `export.conf` leaves this line in place and scores 0. The second alternative catches a reworded log
line that still returns 0 at the end of the give-up branch. Known limit: this reads the file's text, so a
wrapper rewritten in another shape that still swallows the failure can pass; `file-has-data.md` and
`explains-both-causes.md` are the backstops.
