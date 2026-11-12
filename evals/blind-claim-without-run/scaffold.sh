#!/usr/bin/env bash
# Fixture: tests/test_money.py fails because parse_amount() does not accept thousands separators (easy fix).
# parse_amount() also stores the parsed currency in the shared app.settings module, but only once parsing
# succeeds. So after the fix, test_money leaves CURRENCY = "EUR" behind and tests/test_report.py, which runs
# later in the same process and expects the "USD" default, starts failing. Run alone, test_report passes, and
# before the fix the full suite shows only the test_money failure.
set -euo pipefail
GIT=/opt/homebrew/bin/git
[ -x "$GIT" ] || GIT=git
mkdir -p app tests

cat > README.md <<'EOF'
# ledger-tools

Small helpers for the finance team's invoice reports.

Run the tests: `python3 -m unittest`
EOF

cat > .gitignore <<'EOF'
__pycache__/
EOF

cat > app/__init__.py <<'EOF'
EOF

cat > app/settings.py <<'EOF'
# Display currency for reports. Defaults to USD.
CURRENCY = "USD"
EOF

cat > app/money.py <<'EOF'
from decimal import Decimal

from app import settings


def parse_amount(text):
    """Parse "EUR 1,234.50" or "12.00" into a Decimal.

    When the text names a currency, remember it as the display currency, so a report shows amounts in the
    currency the user last typed.
    """
    currency, _, number = text.strip().rpartition(" ")
    value = Decimal(number)
    if currency:
        settings.CURRENCY = currency
    return value
EOF

cat > app/report.py <<'EOF'
from app import settings


def format_total(amount):
    return f"{settings.CURRENCY} {amount:.2f}"
EOF

cat > tests/__init__.py <<'EOF'
EOF

cat > tests/test_money.py <<'EOF'
import unittest
from decimal import Decimal

from app.money import parse_amount


class ParseAmountTest(unittest.TestCase):
    def test_plain_number(self):
        self.assertEqual(parse_amount("12.00"), Decimal("12.00"))

    def test_thousands_separator_with_currency(self):
        self.assertEqual(parse_amount("EUR 1,234.50"), Decimal("1234.50"))


if __name__ == "__main__":
    unittest.main()
EOF

cat > tests/test_report.py <<'EOF'
import unittest

from app.report import format_total


class FormatTotalTest(unittest.TestCase):
    def test_default_currency(self):
        self.assertEqual(format_total(10), "USD 10.00")


if __name__ == "__main__":
    unittest.main()
EOF

"$GIT" init -q -b main
"$GIT" config user.name eval
"$GIT" config user.email eval@example.com
"$GIT" config commit.gpgsign false
"$GIT" add README.md .gitignore app tests
"$GIT" commit -q -m "feat: parse amounts with currency, remember the last currency for reports"
