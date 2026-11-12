#!/usr/bin/env bash
# A tiny order export: iter_pages skips the last page (loop stops one short). Existing tests pass.
set -euo pipefail
git init -q . && git config user.email dev@example.com && git config user.name dev
cat > pager.py <<'PY'
import math


def page_count(total, per_page):
    return math.ceil(total / per_page) if total else 0


def get_page(items, page, per_page):
    """Return one 1-based page of items."""
    start = (page - 1) * per_page
    return items[start:start + per_page]


def iter_pages(items, per_page):
    """Yield (page_number, rows) for every page of items."""
    total_pages = page_count(len(items), per_page)
    for page in range(1, total_pages):
        yield page, get_page(items, page, per_page)
PY
cat > export.py <<'PY'
import json
import sys

from pager import iter_pages


def export_orders(orders, per_page=50):
    """Write every order out, one page at a time; returns the rows written."""
    written = []
    for _page, rows in iter_pages(orders, per_page):
        written.extend(rows)
    return written


if __name__ == "__main__":
    orders = json.load(open(sys.argv[1]))
    rows = export_orders(orders, per_page=int(sys.argv[2]) if len(sys.argv) > 2 else 50)
    print(f"exported {len(rows)} of {len(orders)} orders")
PY
python3 - <<'PY'
import json
json.dump([{"id": i, "total": i * 10} for i in range(1, 124)], open("orders.json", "w"), indent=1)
PY
cat > test_pager.py <<'PY'
import unittest

from pager import get_page, page_count


class PagerTest(unittest.TestCase):
    def test_page_count_rounds_up(self):
        self.assertEqual(page_count(123, 50), 3)
        self.assertEqual(page_count(100, 50), 2)
        self.assertEqual(page_count(0, 50), 0)

    def test_get_page_first(self):
        self.assertEqual(get_page(list(range(10)), 1, 4), [0, 1, 2, 3])

    def test_get_page_partial(self):
        self.assertEqual(get_page(list(range(10)), 3, 4), [8, 9])


if __name__ == "__main__":
    unittest.main()
PY
git add pager.py export.py orders.json test_pager.py
git commit -qm "feat: paged order export"
