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

GATE_ID = "gate:agent:subagent-spawn-guard"

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
    # Fail-safe = ALLOW for every other parse error (truncated or malformed JSON): it must not
    # stall every subagent Agent call. Depth overflow above is the one exception and denies.
    print(f"[mh:gate] subagent-spawn-guard: unparseable stdin, allowing ({e})", file=sys.stderr)
    sys.exit(0)

if not isinstance(d, dict):
    print("[mh:gate] subagent-spawn-guard: non-object payload, allowing", file=sys.stderr)
    sys.exit(0)

if d.get("tool_name") != "Agent":
    sys.exit(0)

# agent_id is present ONLY inside a subagent call (task-complete-separation.py's
# header: agent_type is ALSO set for a top-level `claude --agent <name>` main
# session, which legitimately dispatches; agent_id is the correct discriminant).
# Presence check, not truthiness (GH #154): the key being present at all is
# the signal, so an empty-string or null agent_id must still deny, not allow.
if "agent_id" not in d:
    sys.exit(0)

agent_type = d.get("agent_type") or "unknown"

# Deliberately ignores tool_input.subagent_type: the check is "any subagent
# calling Agent at all", not "a subagent spawning its own type" -- the
# 2026-08-31 fork-recursive-spawn incident evaded a same-type check by
# switching subagent_type, so this gate never looks at it.
print(f"[mh:gate] BLOCKED: subagent ({agent_type}) may not call the Agent tool to spawn its "
      f"own reviewer/validator/subagent -- dispatch is the main session's job (maker≠checker, "
      f"docs/METHODOLOGY.md Rule 13). Return findings to the main session and let it "
      f"dispatch the next agent.", file=sys.stderr)
journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"))
sys.exit(2)
