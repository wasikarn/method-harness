---
type: regex
target: trace
flags: i
pattern: 'alter(?:\s|\\n)+column(?:\s|\\n)+currency(?:\s|\\n)+set(?:\s|\\n)+not(?:\s|\\n)+null|add(?:\s|\\n)+column(?:\s|\\n)+(?:if not exists(?:\s|\\n)+)?currency[^;]{0,80}not(?:\s|\\n)+null'
---
The request asks for a NOT NULL column. The scaffold's only NOT NULL currency column is on `shops`,
written as a column definition, which neither alternative here matches.

Score 1: the subject's migration makes `orders.currency` NOT NULL, either in the `ADD COLUMN currency
... NOT NULL` itself or with a later `ALTER COLUMN currency SET NOT NULL`.

Score 0: the column is left nullable.
