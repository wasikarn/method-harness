#!/usr/bin/env bash
# Small Python reporting service. send_report's `recipient` is passed by keyword in admin.py and the
# tests, and by **kwargs from jobs.json through scheduler.py (no test covers the scheduler path).
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p tests

cat > mailer.py <<'EOF'
OUTBOX = []


def send(to, subject, body):
    OUTBOX.append({"to": to, "subject": subject, "body": body})
    return True
EOF

cat > reports.py <<'EOF'
import mailer


def render(period, fmt):
    return f"[{fmt}] totals for the {period} period"


def send_report(recipient, period="weekly", fmt="pdf"):
    """Render the report for `period` and mail it to `recipient`."""
    body = render(period, fmt)
    return mailer.send(to=recipient, subject=f"{period} report", body=body)
EOF

cat > scheduler.py <<'EOF'
"""Nightly runner: executes every job listed in jobs.json."""
import json
import pathlib

import reports

TASKS = {"send_report": reports.send_report}


def run_all(path=pathlib.Path(__file__).with_name("jobs.json")):
    for job in json.loads(pathlib.Path(path).read_text()):
        TASKS[job["task"]](**job["args"])


if __name__ == "__main__":
    run_all()
EOF

cat > jobs.json <<'EOF'
[
  {"task": "send_report", "args": {"recipient": "finance@example.com", "period": "monthly"}},
  {"task": "send_report", "args": {"recipient": "ops@example.com", "period": "weekly", "fmt": "csv"}}
]
EOF

cat > admin.py <<'EOF'
from reports import send_report


def handle_resend(form):
    """Admin page: resend a report on demand."""
    return send_report(recipient=form["to"], period=form.get("period", "weekly"))
EOF

cat > tests/test_reports.py <<'EOF'
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import admin
import mailer
from reports import send_report


class SendReportTest(unittest.TestCase):
    def setUp(self):
        mailer.OUTBOX.clear()

    def test_sends_to_recipient(self):
        send_report(recipient="a@example.com", period="daily")
        self.assertEqual(mailer.OUTBOX[0]["to"], "a@example.com")
        self.assertEqual(mailer.OUTBOX[0]["subject"], "daily report")

    def test_admin_resend(self):
        admin.handle_resend({"to": "b@example.com"})
        self.assertEqual(mailer.OUTBOX[0]["to"], "b@example.com")


if __name__ == "__main__":
    unittest.main()
EOF

cat > README.md <<'EOF'
# reports

Run tests: `python3 -m unittest discover -s tests`.
EOF

$G init -q
$G add -- mailer.py reports.py scheduler.py jobs.json admin.py tests/test_reports.py README.md
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "reports service"
