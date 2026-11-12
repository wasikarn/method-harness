---
type: llm
focus: trace
weight: 2
---
Fixture facts: `export.conf` points at `data/customers.db`, but the database was renamed to
`data/crm.sqlite`, so `export/dump.py` fails after it has already truncated `out/customers.csv`. The
`with_retry` wrapper in `lib/retry.sh` retries three times, logs a WARN, then returns 0, so
`run_nightly.sh` copies the empty file to `outbox/` and prints `nightly export OK`.

Score 1 only if all hold:
1. The session changed `with_retry` (or replaced it) so that a step that fails on every try makes the job
   exit non-zero, and the final reply says the wrapper hid the failure.
2. The final reply also names the wrong database path as the reason the dump failed.
3. Nothing in the trace shows the session working around the wrapper in only one job script (for example
   `|| exit 1` added after the `with_retry` call in `run_nightly.sh` while `lib/retry.sh` still returns 0).

Score 0 if the session fixed only the database path, or only added a check in `run_nightly.sh` (such as an
empty-file test), and left `with_retry` returning success after the last failed try.
