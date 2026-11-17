#!/usr/bin/env python3
"""PostToolUse(WebSearch | qmd) sensor: advisory only, never blocks (always exit 0).

CLAUDE.md says to search qmd before WebSearch. A local scan of transcripts since
that rule landed found qmd called before the first web call in 8 of 28 sessions
(docs/research/skill-chain-workflows-design-2026-11-17.md); this sensor nudges once.

Two markers per session under $TMPDIR/mh-sensors, both created with O_EXCL so no lock
is needed: "<session>.qmd" (a qmd tool ran) and "<session>.web" (the first WebSearch
was handled). On the first WebSearch it appends one row to the metrics log, so the
real rate can be read later, and nudges only if no qmd call came before it and the
`qmd` binary is on PATH (qmd is operator-environment, not bundled: no binary, no nudge).
A subagent shares its parent's session_id, so its qmd call counts for the session.
"""
import json
import os
import shutil
import sys
import time

sys.dont_write_bytecode = True
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "_lib"))
    from hook_payload import validate_session_id
except Exception as _e:  # noqa: BLE001 -- any load failure must fail open
    validate_session_id = None
    _LIB_ERROR = repr(_e)[:200]

QMD_PREFIX = "mcp__plugin_qmd_qmd__"
NUDGE = (
    "<mh-qmd-first-nudge>\n"
    "WebSearch ran before any qmd search this session. If the question may be covered by the "
    "operator's notes, search qmd first (llm-wiki collection); for library docs use context7. "
    "News, prices and fresh releases are fine on the web: carry on.\n"
    "</mh-qmd-first-nudge>"
)


def marker_dir():
    return os.environ.get("TMPDIR", "/tmp").rstrip("/") + "/mh-sensors"


def log_path():
    return os.environ.get("MH_QMD_FIRST_LOG") or os.path.expanduser("~/.local/share/kbg/metrics/qmd-first.jsonl")


def create_once(path):
    """True only for the call that creates the marker."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        return True
    except FileExistsError:
        return False


def append_log(row):
    try:
        p = log_path()
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError as e:
        print(f"[mh:sensor] qmd-first-nudge: cannot write {log_path()} ({e}); continuing", file=sys.stderr)


def main(argv):
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict) or data.get("hook_event_name") not in (None, "PostToolUse"):
        return 0
    tool = data.get("tool_name")
    if not isinstance(tool, str):
        return 0
    is_qmd = tool.startswith(QMD_PREFIX)
    if not is_qmd and tool != "WebSearch":
        return 0
    if validate_session_id is None:
        print(f"[mh:sensor] qmd-first-nudge: cannot load scripts/_lib/hook_payload.py ({_LIB_ERROR}); "
              "no nudge", file=sys.stderr)
        return 0
    session = validate_session_id(data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if not session:
        print("[mh:sensor] qmd-first-nudge: session_id is not a safe file name; no nudge", file=sys.stderr)
        return 0
    base = f"{marker_dir()}/qmd-first-{session}"
    try:
        if is_qmd:
            create_once(base + ".qmd")
            return 0
        if not create_once(base + ".web"):
            return 0  # not the first WebSearch of this session
        qmd_first = os.path.exists(base + ".qmd")
    except OSError as e:
        print(f"[mh:sensor] qmd-first-nudge: marker error ({e}); no nudge", file=sys.stderr)
        return 0
    nudge = (not qmd_first) and shutil.which("qmd") is not None
    append_log({"ts": int(time.time()), "session": session, "qmd_before_web": qmd_first, "nudged": nudge})
    if nudge:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": NUDGE}}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
