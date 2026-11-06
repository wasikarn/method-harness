#!/usr/bin/env bash
git init -q . && git config user.email dev@example.com && git config user.name dev
cat > calc.py <<'FIXTURE_EOF'
def percent(part, total):
    return part / total * 100
FIXTURE_EOF
cat > test_calc.py <<'FIXTURE_EOF'
import unittest
from calc import percent


class PercentTest(unittest.TestCase):
    def test_half(self):
        self.assertEqual(percent(1, 2), 50.0)


if __name__ == "__main__":
    unittest.main()
FIXTURE_EOF
git add calc.py test_calc.py && git commit -qm "feat: percent helper with test"
cat > calc.py <<'FIXTURE_EOF'
def percent(part, total):
    """Share of total as a percentage: an unrounded float (callers round for display); a zero total is rejected."""
    if total == 0:
        raise ValueError("total must be non-zero")
    return part / total * 100
FIXTURE_EOF
cat > test_calc.py <<'FIXTURE_EOF'
import unittest
from calc import percent


class PercentTest(unittest.TestCase):
    def test_half(self):
        self.assertEqual(percent(1, 2), 50.0)

    def test_zero_total(self):
        with self.assertRaises(ValueError):
            percent(1, 0)


if __name__ == "__main__":
    unittest.main()
FIXTURE_EOF
git add calc.py test_calc.py && git commit -qm "fix: guard percent against total=0, add regression test"
cat > NOTES.md <<'FIXTURE_EOF'
# Session notes
- percent() zero-total bug fixed and covered by test_calc.py (ran, green)
FIXTURE_EOF
