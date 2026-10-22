#!/usr/bin/env python3
"""PostToolUseFailure(Bash) sensor: on a Codex CLI command failing with a
usage-limit/rate-limit-shaped error, records the failure (and the reset
time when the message names one) so the paired codex-quota-advisory.py can
warn, or deny while that reset is still ahead, before the next Codex dispatch
instead of finding out mid-call again. This sensor itself never blocks
(always exit 0), same posture as failure-diagnose-nudge.py.

Real gap this closes: docs/reference/codex-integration-map.md and
memory's project_codex_usage_limit_hit_twice_2026_09_12.md both record the
Codex CLI's usage quota being exhausted multiple times across sessions with
no automated detection -- every hit was discovered reactively, mid-dispatch.
This sensor (and its paired advisory) doesn't recover Codex availability;
it only stops a doomed retry from spending a round-trip on a window that's
already known to be closed.

Persisted, not session-scoped: a quota retry window can span hours to
days, well past this session's lifetime, unlike failure-diagnose-nudge's
session-scoped nudge cap. State lives under ~/.cache/mh by default,
overridable via MH_CODEX_QUOTA_STATE_FILE (tests point this at a throwaway
path).

Deliberately loose match on the failure text ("usage limit", "rate limit",
"quota") rather than one exact string: the Codex CLI's exact wording is not
a documented contract, and a false positive here only costs one redundant
advisory line later, never a block.
"""
import datetime
import json
import os
import re
import sys
import time

# The bare CLI, or the Codex plugin's own runner (`node .../codex-companion.mjs task ...`),
# which the trailing boundary alone rejects (GH #333).
_CODEX_RE = re.compile(r"(^|[\s/\"'])codex([\s\"']|$)|codex-companion\.mjs")
_QUOTA_RE = re.compile(r"usage\s*limit|rate\s*limit|quota", re.IGNORECASE)
_MAX_MESSAGE_LEN = 500
# "try again at 9:47 PM" or "try again at Oct 4th, 2026 12:15 AM" (the two wordings logged so far).
_RESET_RE = re.compile(
    r"try again at\s+(?:(?P<mon>[A-Za-z]{3})[a-z]*\.?\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?P<year>\d{4})\s+)?"
    r"(?P<hour>\d{1,2}):(?P<min>\d{2})\s*(?P<ap>[AaPp][Mm])",
    re.IGNORECASE,
)
_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}


def default_state_path():
    return os.environ.get("MH_CODEX_QUOTA_STATE_FILE") or os.path.expanduser(
        "~/.cache/mh/codex-quota-state.json"
    )


def looks_like_codex_command(command):
    return bool(_CODEX_RE.search(command))


def looks_like_quota_failure(text):
    return bool(_QUOTA_RE.search(text))


def parse_reset_at(text, now):
    """Epoch seconds (local time) of the reset the message names, else None. A time with no
    date means its next occurrence after `now`; a date it cannot read means no reset."""
    m = _RESET_RE.search(text)
    if not m:
        return None
    hour = int(m.group("hour")) % 12 + (12 if m.group("ap").lower() == "pm" else 0)
    minute = int(m.group("min"))
    try:
        if m.group("mon"):
            mon = _MONTHS[m.group("mon").lower()]
            when = datetime.datetime(int(m.group("year")), mon, int(m.group("day")), hour, minute)
        else:
            today = datetime.datetime.fromtimestamp(now)
            when = today.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if when.timestamp() < now:
                when += datetime.timedelta(days=1)
    except (KeyError, ValueError):
        return None
    return int(when.timestamp())


def extract_command(data):
    ti = data.get("tool_input")
    if isinstance(ti, dict):
        cmd = ti.get("command")
        if isinstance(cmd, str):
            return cmd
    return ""


def record(state_path, message):
    now = int(time.time())
    state = {"recorded_at": now, "message": message[:_MAX_MESSAGE_LEN]}
    reset_at = parse_reset_at(message, now)
    if reset_at is not None:
        state["reset_at"] = reset_at
    try:
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass  # fail-open: losing the record just means no advisory next time, never blocks


def main(argv):
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0
    if data.get("hook_event_name") != "PostToolUseFailure":
        return 0

    command = extract_command(data)
    if not command or not looks_like_codex_command(command):
        return 0

    error = data.get("error")
    if not isinstance(error, str) or not looks_like_quota_failure(error):
        return 0

    state_path = argv[1] if len(argv) > 1 else default_state_path()
    record(state_path, error)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
