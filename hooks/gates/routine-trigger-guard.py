#!/usr/bin/env python3
import json, sys

# GH-adjacent to #156: raise the int-string digit limit before parsing so an
# oversized unquoted int literal doesn't crash json.load() into this gate's
# fail-open except below (full rationale: codex-setup-guard.py).
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

try:
    from _journal import journal
except Exception:
    def journal(*a, **k):
        pass

GATE_ID = "gate:tool:routine-trigger-guard"

try:
    d = json.load(sys.stdin)
except (RecursionError, MemoryError):
    # Depth overflow cannot be checked, so ask, not allow. sys.exit, not os._exit: os._exit drops stdout.
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": "routine-trigger-guard: payload nested too deep to parse; cannot check this RemoteTrigger call -- confirm it is operator-approved."}}))
    journal(GATE_ID, None, "ask", None)
    sys.exit(0)
except Exception as e:
    # Fail-safe = ALLOW for every other parse error: it must not stall a legitimate call.
    print(f"[mh:gate] routine-trigger-guard: unparseable stdin, allowing ({e})", file=sys.stderr)
    sys.exit(0)

if not isinstance(d, dict):
    print("[mh:gate] routine-trigger-guard: non-object payload, allowing", file=sys.stderr)
    sys.exit(0)

tool_name = d.get("tool_name")
if tool_name != "RemoteTrigger":
    # mh:deep-audit (2026-09-28) found CronCreate misclassified here: its own tool
    # description says jobs are session-only, in-memory, and die when this Claude
    # session ends -- it re-enqueues a prompt in the *same*, already-operator-attended
    # session, granting no new credential and starting no new session. It is not a
    # cloud-Routine self-launch vector and was dropped from this gate's scope.
    sys.exit(0)

# RemoteTrigger's own schema names 8 actions; only create/update/run/
# create_webhook_trigger mutate or fire a Routine. list/get/list_runs/get_run_log are
# pure reads with no side effect worth an ask-tier interrupt. mh:deep-audit (2026-09-28)
# found the original version asked on every action, including reads -- narrowed here.
READ_ONLY_ACTIONS = {"list", "get", "list_runs", "get_run_log"}
_raw_action = d.get("tool_input", {}).get("action") if isinstance(d.get("tool_input"), dict) else None
# mh:blind-spot-hunter (2026-09-28) found a non-string action (a list/dict) crashed the
# `in READ_ONLY_ACTIONS` membership check below with an unhandled TypeError -- Claude Code
# treats a non-zero, non-2 hook exit as a non-blocking error and lets the call through with
# no ask, the exact silent-allow this gate exists to prevent. A non-string action can't be
# a recognized read action, so it falls through to asking, same as any other unknown value.
action = _raw_action if isinstance(_raw_action, str) else None
if action in READ_ONLY_ACTIONS:
    sys.exit(0)

# ask, not deny: creating/firing/modifying a Routine (a cloud session that can act
# with no operator present) can be a legitimate, operator-approved action -- ADR 0004
# (docs/adr/0004-operator-authorized-routine-self-launch.md) names this exact gap
# (its own [R1 fix] to §4, item 6 in §5) as required future work: "nothing gates the
# model from creating or firing a Routine in the first place" today. This closes that
# gap for an interactive session, the same shape as Phase B's `gh pr merge` ask-tier
# rule in irrecoverable.py. It does not, and cannot, constrain a Routine that already
# exists and is running outside this Claude Code session -- see the ADR's §4 for why.
# An unrecognized/missing action fails toward asking, not allowing: the cost of an
# extra confirmation is low, the cost of silently allowing a future mutating action
# this gate doesn't yet know about is not.
reason = (
    f"RemoteTrigger action={action!r} may create, modify, or fire a Routine -- a cloud session "
    "that can push and open PRs with no operator present once it runs -- confirm this is "
    "operator-approved before proceeding (docs/adr/0004-operator-authorized-routine-self-launch.md, "
    "still status: proposed)."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "ask",
                                         "permissionDecisionReason": reason}}))
journal(GATE_ID, tool_name, "ask", d.get("session_id"))
