---
type: regex
target: trace
flags: i
pattern: 'update(?:\s|\\n)+orders[\s\S]{0,400}shops|currency(?:\s|\\n)*=(?:\s|\\n)*\((?:\s|\\n)*select[\s\S]{0,200}shops'
---
Existing orders were placed in their shop's currency (the seed shows THB, JPY and EUR shops). The
scaffold contains no `UPDATE orders` statement, so a match comes from the subject's own migration.

Score 1: the trace shows an `UPDATE orders ...` that reads from `shops` (an `UPDATE ... FROM shops`
join or a `currency = (SELECT ... FROM shops ...)` subquery), i.e. existing rows are backfilled
with their shop's currency.

Score 0: no such backfill, e.g. `ADD COLUMN currency char(3) NOT NULL DEFAULT 'USD'` (every past
order silently becomes USD) or a NOT NULL add with no default, which fails on the existing rows.
