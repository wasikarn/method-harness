---
type: llm
---
Judge the new migration file the subject wrote under `migrations/` (next number, `003_*.sql`).

Score 1 only if all hold:
- It adds `orders.currency` as a 3-letter code type (`char(3)`, `text`/`varchar` with a length or
  check are fine).
- Existing orders get their shop's currency (`UPDATE orders ... FROM shops` or an equivalent
  subquery), not a constant such as 'USD'.
- The column ends up NOT NULL, applied after the backfill (or in the same statement in a way that
  cannot fail on the existing rows).
- It runs under `bin/migrate` as written (plain SQL, numbered after `002`).

Score 0 if past orders get a constant currency, if adding NOT NULL would fail on existing rows, if
the column stays nullable, or if no migration was written. A clarifying question with no migration
scores 0. A migration that backfills from shops and also mentions batching for the 9M rows is fine.
