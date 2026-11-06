#!/usr/bin/env bash
git init -q . && git config user.email t@example.com && git config user.name t
mkdir -p src tests
cat > src/retry.py <<'FIXTURE_EOF'
import time

def backoff(attempt, base=0.5):
    # attempt is 1-based; the first retry waits base seconds
    return base * (2 ** (attempt - 1))

def with_retry(fn, attempts=3, sleep=time.sleep):
    last = None
    for i in range(1, attempts + 1):
        try:
            return fn()
        except Exception as e:
            last = e
            if i < attempts:
                sleep(backoff(i))
    raise last
FIXTURE_EOF
cat > tests/test_retry.py <<'FIXTURE_EOF'
import unittest
from src.retry import backoff, with_retry

class RetryTests(unittest.TestCase):
    def test_backoff_first_retry_waits_base(self):
        self.assertEqual(backoff(1), 0.5)

    def test_with_retry_sleeps_between_attempts_only(self):
        calls = []
        n = {"i": 0}
        def fn():
            n["i"] += 1
            if n["i"] < 3:
                raise ValueError("flaky")
            return "ok"
        self.assertEqual(with_retry(fn, attempts=3, sleep=calls.append), "ok")
        self.assertEqual(calls, [0.5, 1.0])
FIXTURE_EOF
git add src tests && git commit -qm "feat: retry helper"
sed -i.bak 's/return base \* (2 \*\* (attempt - 1))/return base * (2 ** attempt)/' src/retry.py && rm src/retry.py.bak
git commit -qam "refactor: simplify backoff exponent"
sed -i.bak 's/return base \* (2 \*\* attempt)/return base * (2 ** (attempt - 1))/' src/retry.py && rm src/retry.py.bak
git commit -qam "fix(retry): backoff used a 0-based exponent on a 1-based attempt, doubling every wait (gh-77); covered by test_backoff_first_retry_waits_base"
git log --oneline > GITLOG.txt
