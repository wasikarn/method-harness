---
type: regex
pattern: 'ada@example\.com'
target:
  source: file
  path: outbox/customers.csv
---
`export.conf` still points at `data/customers.db`, renamed to `data/crm.sqlite` in the last commit. The
dump fails with `no such table` after opening (and emptying) the output file. The session fixed the path
and re-ran the job, so `outbox/customers.csv` now holds the customer rows.
