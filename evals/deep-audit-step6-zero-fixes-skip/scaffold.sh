#!/usr/bin/env bash
git init -q . && git config user.email dev@example.com && git config user.name dev
echo "demo project" > README.md
git add README.md && git commit -qm "baseline"
cat > math_utils.py <<'FIXTURE_EOF'
def add(a, b):
    return a + b

def average(numbers):
    if not numbers:
        raise ValueError("cannot average an empty list")
    return sum(numbers) / len(numbers)
FIXTURE_EOF
cat > test_math_utils.py <<'FIXTURE_EOF'
import unittest
from math_utils import add, average

class TestMathUtils(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_average(self):
        self.assertEqual(average([2, 4, 6]), 4)

    def test_average_empty_raises(self):
        with self.assertRaises(ValueError):
            average([])
FIXTURE_EOF
cat > NOTES.md <<'FIXTURE_EOF'
Session notes
=============
- Implemented add() and average(), with average() raising ValueError on an empty list.
- All tests pass.
FIXTURE_EOF
git add math_utils.py test_math_utils.py NOTES.md && git commit -qm "add math utils"
