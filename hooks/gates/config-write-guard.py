#!/usr/bin/env python3
import sys, json, os

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

GATE_ID = "gate:write:config-guard"

def emit_ask(reason, tool_name, session_id):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    journal(GATE_ID, tool_name, "ask", session_id)

SECURITY_KEYS = ("hooks", "enabledPlugins", "env")

def reconstruct(tool, ti, old_raw):
    # Returns the new file content the tool call would produce, or None if
    # it cannot be determined from the payload alone.
    if tool == "Write":
        content = ti.get("content")
        return content if isinstance(content, str) else None
    if tool == "Edit":
        old_s = ti.get("old_string")
        new_s = ti.get("new_string")
        if not isinstance(old_s, str) or not isinstance(new_s, str):
            return None
        if old_s not in old_raw:
            return None
        count = -1 if ti.get("replace_all") else 1
        return old_raw.replace(old_s, new_s, count)
    return None

def security_keys(raw):
    # Returns the SECURITY_KEYS tuple of values, or None if raw cannot be
    # parsed as a JSON object -- "unverifiable," handled the same as a
    # genuine mismatch by the caller.
    try:
        parsed = json.loads(raw)
    except Exception:
        return None
    if not isinstance(parsed, dict):
        return None
    return tuple(parsed.get(k) for k in SECURITY_KEYS)

try:
    try:
        d = json.load(sys.stdin)
    except (RecursionError, MemoryError):
        # Depth overflow: the payload cannot be checked, so ask. Other parse errors still allow below.
        emit_ask("config-write-guard: payload nested too deep to parse, so this write was not checked; approve only if expected.", None, None)
        sys.exit(0)
    tool = d.get("tool_name")
    ti = d.get("tool_input")
    if not isinstance(ti, dict):
        sys.exit(0)
    fp = ti.get("file_path")
    if not isinstance(fp, str) or not fp:
        sys.exit(0)

    # normpath only -- deliberately NOT realpath. This gate classifies
    # "is something already sitting at this path," and realpath would
    # resolve a dangling symlink to its (missing) target and misreport it
    # as absent. lexists() below is the actual existence check.
    path = os.path.normpath(os.path.expanduser(fp))
    parent, base = os.path.split(path)
    # Case-INsensitive basename/parent match, same reasoning as
    # macOS/APFS is case-insensitive
    # but case-preserving, so ".claude/SETTINGS.JSON" resolves to the same
    # on-disk file as ".claude/settings.json" while a case-sensitive string
    # compare treats them as unrelated -- a one-character-case Write/Edit
    # would otherwise skip this gate entirely on this exact filesystem.
    # Lowercasing only widens the match (more asks, never fewer), so this is
    # safe on case-sensitive filesystems too.
    if base.lower() not in ("settings.json", "settings.local.json"):
        sys.exit(0)
    if os.path.basename(parent).lower() != ".claude":
        sys.exit(0)

    if not os.path.lexists(path):
        emit_ask(
            "config-write-guard: creating a new Claude Code settings file (" + path +
            ") -- a fresh, unreviewed behavior surface. Confirm this is intentional.",
            tool, d.get("session_id"),
        )
        sys.exit(0)

    # MODIFY of an existing file (or a symlink already there). Frictionless
    # unless the edit touches a SECURITY_KEYS entry -- read the current
    # content and compare against what the edit would produce.
    try:
        with open(path, "r") as f:
            old_raw = f.read()
    except (OSError, UnicodeDecodeError):
        # OSError: dangling symlink or unreadable. UnicodeDecodeError: the
        # on-disk file has a non-UTF-8 byte somewhere -- NOT an OSError
        # subclass, so this needs its own arm. Without it, a single stray
        # invalid byte anywhere in the file (from prior corruption or an
        # unrelated Bash-mediated write) would fall through to the outer
        # bare except and silently allow every subsequent Write/Edit against
        # this file, including one that rewrites a SECURITY_KEYS entry --
        # defeating the exact path this gate exists to cover. Cannot verify
        # either way, so treat it the same as unreadable.
        old_raw = None

    old_keys = security_keys(old_raw) if old_raw is not None else None
    new_raw = reconstruct(tool, ti, old_raw) if old_raw is not None else None
    new_keys = security_keys(new_raw) if new_raw is not None else None

    if old_keys is not None and new_keys is not None and old_keys == new_keys:
        sys.exit(0)  # verified unchanged -- no friction

    emit_ask(
        "config-write-guard: this edit to " + path +
        " could not be verified to leave hooks/enabledPlugins/env unchanged " +
        "(unreadable original, unparseable content, or a real change to " +
        "one of those keys). Confirm this is intentional.",
        tool, d.get("session_id"),
    )
except Exception as e:
    # 2026-09-20 audit: observability only -- this stays fail-open by design
    # (a pre-existing, intentional safety net for a genuinely unexpected
    # error, per this gate's .sh wrapper header), not a change to the
    # decision path. The gap was that a crash here produced zero diagnostic,
    # indistinguishable from "nothing to ask about" -- every sibling gate's
    # parse-guard already prints a stderr note for the same class of failure.
    print(f"[mh:gate] config-write-guard: internal error, allowing ({e})", file=sys.stderr)
    sys.exit(0)
