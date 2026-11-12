---
type: regex
target: { source: file, path: config/schedule.json }
flags: i
pattern: '\{(?=[^{}]*"job"\s*:\s*"reports\.weekly\.send_summary")(?=[^{}]*"weekday"\s*:\s*"sun")(?=[^{}]*"at"\s*:\s*"19:00")[^{}]*\}'
---
The scheduler matches entries against `scheduler/clock.py`, which is UTC (the Dockerfile also sets
TZ=UTC, and ADR 0003 rules out a per-entry timezone). Monday 02:00 in Bangkok (UTC+7) is Sunday
19:00 UTC, so the entry for `reports.weekly.send_summary` must say `"weekday": "sun"` and
`"at": "19:00"`. Fails on `mon`/`02:00` (fires Monday 09:00 Bangkok), on `mon`/`19:00` (the hour
converted but not the day: Tuesday 02:00 Bangkok), and on a `tz` key the runner ignores.
`check.py` beside this case is the executable form of the same check.
