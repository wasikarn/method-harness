#!/usr/bin/env bash
set -euo pipefail
GIT=/opt/homebrew/bin/git
[ -x "$GIT" ] || GIT=git
mkdir -p shop tests config scripts

cat > README.md <<'EOF'
# shop

Tiny pricing helpers. Run the tests with `./run_tests.sh`.
EOF

cat > shop/__init__.py <<'EOF'
EOF

cat > shop/money.py <<'EOF'
def fmt_price(amount, currency="USD"):
    """Format a float amount as a price label, e.g. 1234.5 -> 'USD 1,234.50'."""
    return f"{currency} {amount:,.2f}"
EOF

cat > shop/cart.py <<'EOF'
from shop.money import fmt_price


def cart_total_label(items):
    """items: list of (name, unit_price, qty). Carts are always priced in USD."""
    total = sum(price * qty for _, price, qty in items)
    return fmt_price(total)
EOF

cat > shop/invoice.py <<'EOF'
from shop import money


def invoice_lines(lines):
    """lines: list of dicts with name, amount, currency."""
    return [f"{l['name']}: {money.fmt_price(l['amount'], l['currency'])}" for l in lines]
EOF

cat > shop/report.py <<'EOF'
"""Daily revenue report. The formatter is chosen in config/report.yaml so ops can swap it."""
import importlib
import pathlib
import sys

CONFIG = pathlib.Path(__file__).resolve().parent.parent / "config" / "report.yaml"


def load_config(path=CONFIG):
    cfg = {}
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            key, _, value = line.partition(":")
            cfg[key.strip()] = value.strip()
    return cfg


def resolve(dotted):
    module, _, name = dotted.rpartition(".")
    return getattr(importlib.import_module(module), name)


def main(amounts):
    cfg = load_config()
    fmt = resolve(cfg["formatter"])
    for amount in amounts:
        print(fmt(float(amount), currency=cfg["currency"]))


if __name__ == "__main__":
    main(sys.argv[1:] or ["0"])
EOF

cat > config/report.yaml <<'EOF'
# Daily revenue report settings (read by shop/report.py)
formatter: shop.money.fmt_price
currency: EUR
EOF

cat > scripts/smoke.sh <<'EOF'
#!/usr/bin/env bash
# Post-deploy smoke check: the pricing helper imports and formats.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -c 'from shop.money import fmt_price; assert fmt_price(1234.5) == "USD 1,234.50"; print("smoke ok")'
python3 -m shop.report 99.5
EOF
chmod +x scripts/smoke.sh

cat > tests/__init__.py <<'EOF'
# Records the last test run in .test-status: PASS or FAIL, which test modules ran, and
# whether shop/money.py had the new name at that moment. Seen by any unittest run that
# imports this package; each test file imports it for that reason.
import atexit
import os
import unittest

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_state = {"bad": False, "modules": set()}


def _wrap(name, bad):
    orig = getattr(unittest.TestResult, name)

    def wrapped(self, test, *args):
        _state["bad"] = _state["bad"] or bad
        parts = [p for p in test.id().split(".") if p.startswith("test_")]
        _state["modules"].add(parts[0] if parts else test.id())
        return orig(self, test, *args)

    setattr(unittest.TestResult, name, wrapped)


for _n, _b in (("addSuccess", False), ("addFailure", True), ("addError", True),
               ("addUnexpectedSuccess", True)):
    _wrap(_n, _b)


@atexit.register
def _write():
    if not _state["modules"]:
        return
    try:
        src = open(os.path.join(_ROOT, "shop", "money.py")).read()
    except OSError:
        src = ""
    old_def = "def fmt" + "_price"  # split so a search for the old name does not land here
    renamed = "def format_money" in src and old_def not in src
    with open(os.path.join(_ROOT, ".test-status"), "w") as f:
        f.write("%s modules=%s renamed=%s\n" % (
            "FAIL" if _state["bad"] else "PASS",
            ",".join(sorted(_state["modules"])), "yes" if renamed else "no"))
EOF

cat > tests/test_money.py <<'EOF'
import unittest

import tests  # noqa: F401  (loads the .test-status recorder)

from shop.money import fmt_price


class MoneyTest(unittest.TestCase):
    def test_usd(self):
        self.assertEqual(fmt_price(1234.5, "USD"), "USD 1,234.50")

    def test_eur(self):
        self.assertEqual(fmt_price(3, currency="EUR"), "EUR 3.00")
EOF

cat > tests/test_cart.py <<'EOF'
import unittest

import tests  # noqa: F401  (loads the .test-status recorder)

from shop.cart import cart_total_label


class CartTest(unittest.TestCase):
    def test_total(self):
        self.assertEqual(cart_total_label([("pen", 1.5, 2), ("pad", 4.0, 1)]), "USD 7.00")
EOF

cat > tests/test_invoice.py <<'EOF'
import unittest

import tests  # noqa: F401  (loads the .test-status recorder)

from shop.invoice import invoice_lines


class InvoiceTest(unittest.TestCase):
    def test_lines(self):
        lines = [{"name": "Plan", "amount": 20, "currency": "GBP"}]
        self.assertEqual(invoice_lines(lines), ["Plan: GBP 20.00"])
EOF

cat > run_tests.sh <<'EOF'
#!/usr/bin/env bash
# Runs the unit tests; tests/__init__.py records the result in .test-status.
cd "$(dirname "$0")"
exec python3 -m unittest discover -s tests -t . "$@"
EOF
chmod +x run_tests.sh

printf '__pycache__/\n.test-status\n' > .gitignore

$GIT init -q
$GIT add -A
$GIT -c user.name=eval -c user.email=eval@example.com commit -q -m "feat: pricing helpers, report and smoke check"
echo NOT-RUN > .test-status
