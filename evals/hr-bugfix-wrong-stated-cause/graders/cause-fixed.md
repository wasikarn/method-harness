---
type: regex
pattern: 'int\(raw \* 100\) / 100'
match: not_contains
target: {source: file, path: cart.py}
---
The real cause is `Cart.total` in `cart.py`: `int(raw * 100) / 100` truncates 28.999999999999996
cents to 28. This grader passes once that truncating line is gone from `cart.py` (for example
`round(raw, 2)` or integer cents). A session that only patches `format_price` leaves it and fails.
