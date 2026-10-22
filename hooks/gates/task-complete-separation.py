#!/usr/bin/env python3
import json, os, sys

# GH #156: raise the int-string digit limit before parsing so an oversized
# unquoted int literal doesn't crash json.load() into this gate's fail-open
# except below (full rationale: codex-setup-guard.py). hasattr-guarded: the
# method doesn't exist before Python 3.11.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

try:
    from _journal import journal
except Exception:
    def journal(*a, **k):
        pass

GATE_ID = "gate:task:complete-separation"

try:
    d = json.load(sys.stdin)
except (RecursionError, MemoryError):
    # Fail-closed, same as subagent-git-guard.py: Claude Code never sends a payload this deep.
    try:
        print("[mh:gate] BLOCKED: PreToolUse payload nested too deep to parse -- failing closed", file=sys.stderr, flush=True)
        journal(GATE_ID, None, "deny", None)
    finally:
        os._exit(2)
except Exception as e:
    # Fail-safe = ALLOW for every other parse error. Completion is recoverable; a parse
    # error must not stall all task completion. Depth overflow above is the one exception.
    print(f"[mh:gate] task-complete-separation: unparseable stdin, allowing ({e})", file=sys.stderr)
    sys.exit(0)

if not isinstance(d, dict):
    # A valid-JSON-but-non-object payload (e.g. a bare list) crashed here
    # too, one level above the tool_input guard below (found 2026-08-06).
    print("[mh:gate] task-complete-separation: non-object payload, allowing", file=sys.stderr)
    sys.exit(0)

if d.get("tool_name") != "TaskUpdate":
    sys.exit(0)

# status has no documented key-name alias; read it straight from tool_input.
ti = d.get("tool_input")
if not isinstance(ti, dict):
    # Matches irrecoverable.sh: a malformed
    # tool_input must not crash into an uncaught traceback (found
    # 2026-08-06). This gate is fail-safe=ALLOW by design, so route
    # straight to the same clean exit a missing status already takes,
    # instead of a silent {} fallback that raised AttributeError.
    sys.exit(0)
status = ti.get("status")
if status != "completed":
    sys.exit(0)

# agent_id is present ONLY when the hook fires inside an actual subagent
# call (code.claude.com/docs/en/hooks, confirmed 2026-08-31). agent_type is
# a broader field -- it is ALSO set for a top-level `claude --agent <name>`
# MAIN session, which legitimately owns completion, so keying on agent_type
# alone over-blocked that case (found by security review of the sibling
# agent-recursion-guard.sh gate, 2026-08-31 -- same bug, same fix, here).
# Presence, not truthiness: an empty-string or null agent_id is still the
# signal (GH #155, same gap as #154's subagent-spawn-guard.py fix).
if "agent_id" not in d:
    sys.exit(0)
agent_id = d.get("agent_id")

agent_type = d.get("agent_type") or "unknown"
print(f"[mh:gate] BLOCKED: subagent ({agent_type}) may not mark its own task completed — "
      f"return to main session for completion (maker≠checker)", file=sys.stderr)
journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"))
sys.exit(2)
