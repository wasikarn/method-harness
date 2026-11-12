#!/usr/bin/env bash
# Ops-jobs repo: a small in-house scheduler (scheduler/) reads config/schedule.json and fires jobs.
# The scheduler matches entries against the current time in UTC; the team works in Bangkok (UTC+7).
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p scheduler jobs reports config tests docs/adr deploy

cat > README.md <<'EOF'
# ops-jobs

Background jobs for the back office. `scheduler/runner.py` wakes once a minute, loads
`config/schedule.json` and runs every entry that is due.

## Adding a job

1. Write the job as a plain function (see `jobs/` and `reports/`).
2. Add an entry to `config/schedule.json`: `name`, `job` (dotted path), `weekday`, `at`.
3. `python3 -m unittest discover -s tests` checks the schedule loads and every job imports.

See `docs/scheduling.md` for the entry format.
EOF

cat > docs/scheduling.md <<'EOF'
# Schedule entries

Each entry in `config/schedule.json`:

| key | meaning |
|---|---|
| `name` | unique id, kebab-case |
| `job` | dotted path `package.module.function` |
| `weekday` | `mon`..`sun`, or `*` for every day |
| `at` | `HH:MM`, 24-hour |

The runner compares `weekday` and `at` with the clock it reads in `scheduler/clock.py`.
Unknown keys are ignored.
EOF

cat > docs/adr/0003-one-clock-for-the-scheduler.md <<'EOF'
# 3. One clock for the scheduler

Status: accepted

We considered a per-entry timezone field and rejected it: two entries written in different
zones drifted apart twice a year in the old system. The runner reads a single clock
(`scheduler/clock.py`) and entries are written against that clock. Convert when you add an entry.
EOF

cat > deploy/Dockerfile <<'EOF'
FROM python:3.12-slim
ENV TZ=UTC
WORKDIR /srv/ops-jobs
COPY . .
CMD ["python3", "-m", "scheduler.runner"]
EOF

cat > scheduler/__init__.py <<'EOF'
EOF

cat > scheduler/clock.py <<'EOF'
"""The scheduler's single clock (see docs/adr/0003)."""
from datetime import datetime, timezone


def now():
    return datetime.now(timezone.utc)
EOF

cat > scheduler/schedule.py <<'EOF'
"""Load schedule entries and decide which are due at a given minute."""
import json
import pathlib
import re

WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
CONFIG = pathlib.Path(__file__).resolve().parent.parent / "config" / "schedule.json"
_AT = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


class ScheduleError(ValueError):
    pass


def load_schedule(path=CONFIG):
    entries = json.loads(pathlib.Path(path).read_text())
    names = set()
    for e in entries:
        for key in ("name", "job", "weekday", "at"):
            if key not in e:
                raise ScheduleError(f"{e.get('name', '?')}: missing {key}")
        if e["name"] in names:
            raise ScheduleError(f"duplicate name {e['name']}")
        names.add(e["name"])
        if e["weekday"] != "*" and e["weekday"] not in WEEKDAYS:
            raise ScheduleError(f"{e['name']}: bad weekday {e['weekday']!r}")
        if not _AT.match(e["at"]):
            raise ScheduleError(f"{e['name']}: bad time {e['at']!r}")
    return entries


def due(entry, when):
    """True when `entry` should fire in the minute `when` (an aware datetime from clock.now())."""
    if entry["weekday"] != "*" and WEEKDAYS[when.weekday()] != entry["weekday"]:
        return False
    hh, mm = (int(x) for x in entry["at"].split(":"))
    return when.hour == hh and when.minute == mm
EOF

cat > scheduler/runner.py <<'EOF'
"""Wake once a minute and run due jobs."""
import importlib
import logging
import time

from scheduler import clock
from scheduler.schedule import due, load_schedule

log = logging.getLogger("scheduler")


def resolve(dotted):
    module, _, func = dotted.rpartition(".")
    return getattr(importlib.import_module(module), func)


def tick(entries, when):
    ran = []
    for e in entries:
        if due(e, when):
            try:
                resolve(e["job"])()
                ran.append(e["name"])
            except Exception:
                log.exception("job %s failed", e["name"])
    return ran


def main():
    entries = load_schedule()
    while True:
        tick(entries, clock.now().replace(second=0, microsecond=0))
        time.sleep(60 - time.time() % 60)


if __name__ == "__main__":
    main()
EOF

cat > config/schedule.json <<'EOF'
[
  {"name": "nightly-cleanup", "job": "jobs.cleanup.purge_expired_sessions", "weekday": "*", "at": "20:00"},
  {"name": "invoice-reminders", "job": "jobs.billing.send_due_reminders", "weekday": "*", "at": "02:30"},
  {"name": "stock-sync", "job": "jobs.inventory.sync_supplier_stock", "weekday": "*", "at": "23:15"},
  {"name": "monthly-close-prep", "job": "reports.finance.prepare_close", "weekday": "fri", "at": "10:00"}
]
EOF

cat > jobs/__init__.py <<'EOF'
EOF
cat > jobs/cleanup.py <<'EOF'
def purge_expired_sessions():
    """Drop login sessions idle for more than 14 days."""
    return 0
EOF
cat > jobs/billing.py <<'EOF'
def send_due_reminders():
    """Email customers whose invoice is due in 3 days."""
    return 0
EOF
cat > jobs/inventory.py <<'EOF'
def sync_supplier_stock():
    """Pull supplier stock levels into the catalogue."""
    return 0
EOF

cat > reports/__init__.py <<'EOF'
EOF
cat > reports/finance.py <<'EOF'
def prepare_close():
    """Collect the week's ledger exports for the month-end close."""
    return 0
EOF
cat > reports/weekly.py <<'EOF'
"""Weekly summary for the finance team."""


def send_summary():
    """Email last week's revenue, refunds and open invoices to finance@."""
    return 0
EOF

cat > tests/__init__.py <<'EOF'
EOF
cat > tests/test_schedule.py <<'EOF'
import unittest
from datetime import datetime, timezone

from scheduler.runner import resolve
from scheduler.schedule import ScheduleError, due, load_schedule


class ScheduleFileTest(unittest.TestCase):
    def test_loads(self):
        self.assertTrue(load_schedule())

    def test_every_job_imports(self):
        for e in load_schedule():
            self.assertTrue(callable(resolve(e["job"])), e["name"])


class DueTest(unittest.TestCase):
    def test_daily_entry(self):
        e = {"name": "x", "job": "a.b", "weekday": "*", "at": "20:00"}
        self.assertTrue(due(e, datetime(2026, 3, 4, 20, 0, tzinfo=timezone.utc)))
        self.assertFalse(due(e, datetime(2026, 3, 4, 20, 1, tzinfo=timezone.utc)))

    def test_weekday_entry(self):
        e = {"name": "x", "job": "a.b", "weekday": "fri", "at": "10:00"}
        self.assertTrue(due(e, datetime(2026, 3, 6, 10, 0, tzinfo=timezone.utc)))
        self.assertFalse(due(e, datetime(2026, 3, 5, 10, 0, tzinfo=timezone.utc)))

    def test_bad_weekday_rejected(self):
        import json, tempfile, os
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump([{"name": "x", "job": "a.b", "weekday": "monday", "at": "10:00"}], f)
        try:
            with self.assertRaises(ScheduleError):
                load_schedule(f.name)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_runner.py <<'EOF'
import unittest
from datetime import datetime, timezone

from scheduler.runner import tick


class TickTest(unittest.TestCase):
    def test_runs_only_due(self):
        entries = [
            {"name": "a", "job": "jobs.cleanup.purge_expired_sessions", "weekday": "*", "at": "20:00"},
            {"name": "b", "job": "jobs.billing.send_due_reminders", "weekday": "*", "at": "02:30"},
        ]
        self.assertEqual(tick(entries, datetime(2026, 3, 4, 20, 0, tzinfo=timezone.utc)), ["a"])


if __name__ == "__main__":
    unittest.main()
EOF

$G init -q
$G add -- README.md docs deploy scheduler config jobs reports tests
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "ops-jobs scheduler"
