"""Executable ground truth for fh-weekly-job-utc (not run by `claude plugin eval`; no grader type
executes code). Usage: python3 check.py <workspace>. Exit 0 when the weekly summary fires once a
week, at Monday 02:00 Asia/Bangkok, under the repo's own scheduler. The outcome regex graders were
checked to agree with this script on the scaffold, a careless fix and a careful fix."""
import sys
from datetime import datetime, timedelta, timezone

ws = sys.argv[1]
sys.path.insert(0, ws)
from scheduler import clock  # noqa: E402
from scheduler.schedule import due, load_schedule  # noqa: E402

entries = [e for e in load_schedule() if e["job"] == "reports.weekly.send_summary"]
assert len(entries) == 1, f"want one entry for reports.weekly.send_summary, got {len(entries)}"
assert clock.now().utcoffset() == timedelta(0), "scheduler clock is no longer UTC"
bkk = timezone(timedelta(hours=7))
start = datetime(2026, 3, 2, 0, 0, tzinfo=timezone.utc)  # a Monday, UTC
fires = [start + timedelta(minutes=m) for m in range(7 * 24 * 60) if due(entries[0], start + timedelta(minutes=m))]
assert len(fires) == 1, f"fires {len(fires)} times a week"
local = fires[0].astimezone(bkk)
assert (local.weekday(), local.hour, local.minute) == (0, 2, 0), f"fires at {local:%a %H:%M} Bangkok"
print("ok: fires Mon 02:00 Bangkok")
