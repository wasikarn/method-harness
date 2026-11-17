#!/usr/bin/env python3
"""PostToolUse(WebSearch | Firecrawl search | qmd) sensor: advisory only, never blocks (always exit 0).

CLAUDE.md says to search qmd before WebSearch. A local scan of transcripts since that
rule landed found qmd called before the first web call in 8 of 28 sessions (29%); this
sensor nudges once per thread and logs the real rate.

Markers under $TMPDIR/mh-sensors, each created with O_EXCL so no lock is needed:
"qmd-first-<session>.qmd" (a qmd tool ran anywhere in the session; a subagent shares its
parent's session_id, so its qmd call counts) and "qmd-first-<session>[-<agent>].web" (the
first search of that thread was handled). The web marker is per thread, like the sibling
failure-diagnose-nudge counter (GH #463): a nudge landing in a subagent's context would
be thrown away and the main thread never warned. On a thread's first search it appends
one row to the metrics log and nudges only if no qmd call came before it and the `qmd`
binary is on PATH (qmd is operator-environment, not bundled: no binary, no nudge). A
session that calls qmd and never searches the web writes no row. Row fields: ts (seconds, ms
precision), session, subagent, agent_id (null on the main thread), qmd_before_web (was any qmd
call in the session already recorded when this thread searched, so a subagent row can read true
because the main thread called qmd first), nudged. Per-session rate: take the earliest row.

Limits: parallel tool calls in one turn have no fixed PostToolUse order, so a session can
be logged as a violation when qmd ran in the same turn (shortcut: accepted, the rate is
a rough one). Only the plugin qmd server (QMD_PREFIX, same literal as the hooks.json
matcher) and the Firecrawl connector search are recognised. When the shared hook_payload
lib cannot load there is no safe marker name, so this sensor stays silent where the sibling
nudges uncapped: one nudge per search would be noise, not advice.
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

QMD_PREFIX = "mcp__plugin_qmd_qmd__"  # keep in step with the hooks.json matcher
SEARCH_TOOLS = ("WebSearch", "mcp__claude_ai_Firecrawl__firecrawl_search")  # likewise
NUDGE = (
    "<mh-qmd-first-nudge>\n"
    "A web search ran before any qmd search this session. If the question may be covered by the "
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
    p = log_path()
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError as e:
        print(f"[mh:sensor] qmd-first-nudge: cannot write {p} ({e}); continuing", file=sys.stderr)


def main():
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
    if not is_qmd and tool not in SEARCH_TOOLS:
        return 0
    if validate_session_id is None:
        print(f"[mh:sensor] qmd-first-nudge: cannot load scripts/_lib/hook_payload.py ({_LIB_ERROR}); "
              "no nudge", file=sys.stderr)
        return 0
    session = validate_session_id(data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if not session:
        print("[mh:sensor] qmd-first-nudge: session_id is not a safe file name; no nudge", file=sys.stderr)
        return 0
    # agent_id is present ONLY inside a subagent: test presence, not truthiness (as the sibling does).
    agent = None
    if "agent_id" in data:
        agent = validate_session_id(data["agent_id"])
        if not agent:
            print("[mh:sensor] qmd-first-nudge: agent_id is not a safe file name; no nudge", file=sys.stderr)
            return 0
    base = f"{marker_dir()}/qmd-first-{session}"
    try:
        if is_qmd:
            create_once(base + ".qmd")
            return 0
        if not create_once(base + (f"-{agent}" if agent else "") + ".web"):
            return 0  # not this thread's first search
        qmd_first = os.path.exists(base + ".qmd")
    except OSError as e:
        print(f"[mh:sensor] qmd-first-nudge: marker error ({e}); no nudge", file=sys.stderr)
        return 0
    nudge = (not qmd_first) and shutil.which("qmd") is not None
    append_log({"ts": round(time.time(), 3), "session": session, "subagent": agent is not None,
                "agent_id": agent, "qmd_before_web": qmd_first, "nudged": nudge})
    if nudge:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": NUDGE}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
