#!/usr/bin/env bash
# No rollback line on purpose: lens 8's size rule says a change `git revert` fully undoes has no rollback gap.
set -e
git init -q . && git config user.email dev@example.com && git config user.name dev
mkdir -p src tests
: > src/__init__.py
: > tests/__init__.py
printf '__pycache__/\n' > .gitignore
cat > src/worker.py <<'FIXTURE_EOF'
"""Run a job, retrying it when a downstream call fails transiently."""


class TransientError(Exception):
    """A failure worth retrying, such as a downstream timeout."""


class RetriesExhausted(Exception):
    """The job still failed after max_attempts tries."""


def run_with_retries(job, max_attempts=3):
    """Call job() until it returns, or raise RetriesExhausted after max_attempts failures."""
    if max_attempts < 1:
        raise ValueError("max_attempts must be at least 1")
    tmp = 0
    while True:
        try:
            return job()
        except TransientError as exc:
            tmp += 1
            if tmp >= max_attempts:
                raise RetriesExhausted(f"gave up after {max_attempts} attempts") from exc
FIXTURE_EOF
cat > tests/test_worker.py <<'FIXTURE_EOF'
import unittest

from src.worker import RetriesExhausted, TransientError, run_with_retries


class FlakyJob:
    """Fails with TransientError `failures` times, then returns "done"."""

    def __init__(self, failures):
        self.failures = failures
        self.calls = 0

    def __call__(self):
        self.calls += 1
        if self.calls <= self.failures:
            raise TransientError("timeout")
        return "done"


class RunWithRetriesTest(unittest.TestCase):
    def test_returns_on_first_success(self):
        job = FlakyJob(failures=0)
        self.assertEqual(run_with_retries(job), "done")
        self.assertEqual(job.calls, 1)

    def test_retries_after_transient_failure(self):
        job = FlakyJob(failures=2)
        self.assertEqual(run_with_retries(job, max_attempts=3), "done")
        self.assertEqual(job.calls, 3)

    def test_raises_after_max_attempts(self):
        job = FlakyJob(failures=5)
        with self.assertRaises(RetriesExhausted) as ctx:
            run_with_retries(job, max_attempts=2)
        self.assertEqual(job.calls, 2)
        self.assertIsInstance(ctx.exception.__cause__, TransientError)

    def test_default_is_three_attempts(self):
        job = FlakyJob(failures=5)
        with self.assertRaises(RetriesExhausted):
            run_with_retries(job)
        self.assertEqual(job.calls, 3)

    def test_other_errors_are_not_retried(self):
        calls = []

        def job():
            calls.append(1)
            raise KeyError("missing")

        with self.assertRaises(KeyError):
            run_with_retries(job)
        self.assertEqual(len(calls), 1)

    def test_rejects_max_attempts_below_one(self):
        with self.assertRaises(ValueError):
            run_with_retries(FlakyJob(failures=0), max_attempts=0)


if __name__ == "__main__":
    unittest.main()
FIXTURE_EOF
cat > plan.md <<'FIXTURE_EOF'
# Plan: rename `tmp` to `failed_attempts` in `run_with_retries`

Target: the local variable `tmp` in `run_with_retries()` in `src/worker.py`. It counts failed
attempts. It is local to that one function, so no other function or file changes.

1. Check the new name is free: `grep -rnw failed_attempts src tests` must print nothing.
2. Rename every `tmp` in `run_with_retries()` to `failed_attempts`.
3. Check the rename is complete: `grep -nw tmp src/worker.py` must print nothing.
4. Run `python3 -m unittest -v tests.test_worker`; all 6 tests must pass unchanged.
   `test_raises_after_max_attempts` runs the retry-exhausted branch, so every line that uses
   the counter runs in at least one test.
5. Commit `src/worker.py` alone as `refactor(worker): name the failed-attempts counter`.
FIXTURE_EOF
git add .gitignore plan.md src tests && git commit -qm "feat(worker): run jobs with retries"
