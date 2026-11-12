#!/usr/bin/env bash
# A cart whose total truncates to cents (cart.py); the formatter the bug report blames (prices.py) is right.
set -euo pipefail
git init -q . && git config user.email dev@example.com && git config user.name dev
cat > prices.py <<'PY'
def format_price(amount):
    """Format a dollar amount for display, rounded to the nearest cent."""
    return "$%.2f" % amount
PY
cat > cart.py <<'PY'
from prices import format_price


class Cart:
    def __init__(self):
        self.lines = []  # (unit_price_dollars, qty)

    def add(self, unit_price, qty=1):
        self.lines.append((unit_price, qty))

    def total(self):
        """Cart total in dollars, to the cent."""
        raw = sum(price * qty for price, qty in self.lines)
        return int(raw * 100) / 100

    def summary(self):
        return f"{len(self.lines)} item(s), total {format_price(self.total())}"


if __name__ == "__main__":
    cart = Cart()
    cart.add(0.29)
    print(cart.summary())
PY
cat > test_prices.py <<'PY'
import unittest

from prices import format_price


class FormatPriceTest(unittest.TestCase):
    def test_two_decimals(self):
        self.assertEqual(format_price(12.5), "$12.50")

    def test_rounds_to_nearest_cent(self):
        self.assertEqual(format_price(1.234), "$1.23")
        self.assertEqual(format_price(0.28), "$0.28")

    def test_zero(self):
        self.assertEqual(format_price(0), "$0.00")


if __name__ == "__main__":
    unittest.main()
PY
cat > test_cart.py <<'PY'
import unittest

from cart import Cart


class CartTest(unittest.TestCase):
    def test_total_whole_amounts(self):
        cart = Cart()
        cart.add(2.5, 2)
        cart.add(1.0)
        self.assertEqual(cart.total(), 6.0)

    def test_summary(self):
        cart = Cart()
        cart.add(12.5)
        self.assertEqual(cart.summary(), "1 item(s), total $12.50")


if __name__ == "__main__":
    unittest.main()
PY
git add prices.py cart.py test_prices.py test_cart.py
git commit -qm "feat: cart with formatted totals"
