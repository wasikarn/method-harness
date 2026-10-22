#!/usr/bin/env python3
# GH #474: which mh skills had no recorded use in the last N sessions. Reads
# ~/.local/share/kbg/metrics/skill-usage.jsonl (hooks/session/skill-usage-telemetry.sh: one row per
# model-called or user-typed skill use) and the plugin's own skills/*/*/SKILL.md. Read-only,
# machine-local, never a gate. A session with no skill use leaves no row, so N counts only sessions
# that used some skill; the report says so.
import argparse
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_SESSIONS = 100


def default_log():
    home = os.environ.get("HOME")
    if not home or not os.path.isabs(home):
        return None
    return Path(home) / ".local" / "share" / "kbg" / "metrics" / "skill-usage.jsonl"


def positive_int(s):
    n = int(s)
    if n < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return n


def skills(skills_dir):
    """{name: manual_only} for every skills/*/*/SKILL.md; manual-only = disable-model-invocation: true."""
    found = {}
    for md in sorted(Path(skills_dir).glob("*/*/SKILL.md")):
        head = md.read_text(encoding="utf-8", errors="replace").split("---", 2)
        front = head[1] if len(head) > 2 else ""
        found[md.parent.name] = bool(re.search(r"^disable-model-invocation:\s*true\s*$", front, re.M))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sessions", type=positive_int, default=DEFAULT_SESSIONS)
    ap.add_argument("--log", default=None)
    ap.add_argument("--skills-dir", default=str(Path(__file__).resolve().parents[3]))
    args = ap.parse_args()

    log = Path(args.log) if args.log else default_log()
    if not log or not log.is_file():
        print("Skill usage log not set up.")
        return 0

    rows = []  # (ts, session_id, skill name) for mh rows only
    with open(log, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict) or r.get("plugin") != "mh":
                continue
            ts, sid, name = r.get("ts"), r.get("session_id"), r.get("skill")
            if isinstance(ts, str) and isinstance(sid, str) and isinstance(name, str):
                rows.append((ts, sid, name.split(":", 1)[-1]))
    if not rows:
        print("No skill use logged for mh yet.")
        return 0
    rows.sort()

    # Session ids, oldest first by last use: dedup newest-first, then flip (was O(n^2) list.remove).
    order = list(dict.fromkeys(sid for _, sid, _ in reversed(rows)))[::-1]
    window = set(order[-args.sessions:])
    in_window = {name for _, sid, name in rows if sid in window}
    last_use = {}
    for ts, _, name in rows:
        last_use[name] = ts[:10]
    window_ts = [ts for ts, sid, _ in rows if sid in window]
    found = skills(args.skills_dir)

    print(f"Skill usage: last {len(window)} of {len(order)} sessions with an mh skill use logged "
          f"({window_ts[0][:10]} to {window_ts[-1][:10]}).")
    for title, manual in (("Model-invocable skills with no use in the window", False),
                          ("Manual-only skills with no use in the window", True)):
        unused = [n for n, m in found.items() if m is manual and n not in in_window]
        print(f"{title} ({len(unused)}):")
        for n in unused:
            print(f"  {n:<20} last use: {last_use.get(n, 'never')}")
    print("A session with no skill use leaves no row, so these counts cover sessions that used some skill. "
          "Zero use is not broken: a rare skill (post-mortem, model-bench) or a description that never matches "
          "look the same here; a human looks at the list.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
