#!/usr/bin/env bash
# No rollback line on purpose: lens 8's size rule says a change `git revert` fully undoes has no rollback gap.
cat > plan.md <<'FIXTURE_EOF'
# Plan: rename `tmp` to `retry_count` in the worker loop

Target: `src/worker.py` lines 40-52 (the only file that uses the name; verified with grep).

1. Rename the local variable `tmp` to `retry_count` in `src/worker.py`, lines 40-52.
2. Run `pytest tests/test_worker.py`; all 6 tests must pass unchanged.
3. Commit as `refactor(worker): name the retry counter`.
FIXTURE_EOF
