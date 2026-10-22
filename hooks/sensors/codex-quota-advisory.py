#!/usr/bin/env python3
"""PreToolUse(Bash) sensor: before a Codex CLI command runs, if
codex-quota-sensor.py recently recorded a usage-limit/rate-limit failure,
inject an advisory (additionalContext) naming the recorded message and how
long ago it fired. When the record carries a reset time still in the future,
deny instead: the limit is known to be closed, so the dispatch (and each of a
parallel batch) is doomed. The deny names the state file to delete and
MH_CODEX_QUOTA_DENY=0 (advisory only) as the way out, for a switched account.
A record with no readable reset time only advises, so a wrong signal costs one
redundant line, never a lost dispatch. See codex-quota-sensor.py's docstring
for the gap this closes.

TTL default 24h (MH_CODEX_QUOTA_TTL_SECONDS overrides, tests use a small
value): quota reset windows in the logged incidents ranged hours to days;
past the TTL the record is treated as stale and removed rather than kept
around to warn forever on a limit that has almost certainly reset.
"""
import json
import os
import re
import sys
import time

# Same pattern as codex-quota-sensor.py; keep the two in step (GH #333).
_CODEX_RE = re.compile(r"(^|[\s/\"'])codex([\s\"']|$)|codex-companion\.mjs")
# A real invocation: `codex` as the command word of a segment (after ; & | ( or a newline, past env
# assignments and rtk/env/time-style prefixes), or the companion script. The loose _CODEX_RE above
# only picks who gets the advisory; a deny must not hit `git commit -m "fix codex hook"`.
_INVOKE_RE = re.compile(
    r"(?:^|[;&|(\n])\s*(?:(?:\w+=\S*|env|rtk|proxy|time|nohup|exec)\s+)*(?:\S*/)?codex(?:\s|$)"
    r"|codex-companion\.mjs"
)
_DEFAULT_TTL_SECONDS = 24 * 3600


def default_state_path():
    return os.environ.get("MH_CODEX_QUOTA_STATE_FILE") or os.path.expanduser(
        "~/.cache/mh/codex-quota-state.json"
    )


def ttl_seconds():
    raw = os.environ.get("MH_CODEX_QUOTA_TTL_SECONDS")
    if raw:
        try:
            return int(raw)
        except ValueError:
            pass
    return _DEFAULT_TTL_SECONDS


def deny_enabled():
    return os.environ.get("MH_CODEX_QUOTA_DENY") != "0"


def format_reset(epoch):
    return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(epoch))


def invokes_codex(command):
    return bool(_INVOKE_RE.search(command))


def looks_like_codex_command(command):
    return bool(_CODEX_RE.search(command))


def extract_command(data):
    ti = data.get("tool_input")
    if isinstance(ti, dict):
        cmd = ti.get("command")
        if isinstance(cmd, str):
            return cmd
    return ""


def load_state(state_path):
    try:
        with open(state_path) as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("recorded_at"), int):
            return d
    except (OSError, ValueError):
        pass
    return None


def format_age(age_seconds):
    hours = age_seconds // 3600
    minutes = (age_seconds % 3600) // 60
    return f"{hours}h{minutes}m ago" if hours else f"{minutes}m ago"


def main(argv):
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0
    if data.get("hook_event_name") != "PreToolUse" or data.get("tool_name") != "Bash":
        return 0

    command = extract_command(data)
    if not command or not looks_like_codex_command(command):
        return 0

    state_path = argv[1] if len(argv) > 1 else default_state_path()
    state = load_state(state_path)
    if state is None:
        return 0

    now = int(time.time())
    age = now - state["recorded_at"]
    reset_at = state.get("reset_at")
    reset_ahead = isinstance(reset_at, int) and reset_at > now  # outlives the TTL: a weekly limit can be days out
    if age < 0 or (age > ttl_seconds() and not reset_ahead):
        try:
            os.remove(state_path)
        except OSError:
            pass
        return 0

    if isinstance(reset_at, int):
        if reset_at <= now:  # the window has reopened: the record is spent
            try:
                os.remove(state_path)
            except OSError:
                pass
            return 0
        if deny_enabled() and invokes_codex(command):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"Codex usage limit is closed until {format_reset(reset_at)} "
                        f"(recorded {format_age(age)}: \"{state.get('message', '')}\"). "
                        "Wait, or fall back to Claude and note \"independence reduced for this pass\". "
                        f"Switched account or limit already reset: delete {state_path}, "
                        "or set MH_CODEX_QUOTA_DENY=0 to get the advisory only."
                    ),
                }
            }))
            return 0

    context = (
        "<mh-codex-quota-advisory>\n"
        f"A Codex CLI call recorded a usage-limit/rate-limit failure {format_age(age)}: "
        f"\"{state.get('message', '')}\". This dispatch may fail again for the same reason -- "
        "check whether the limit has reset before retrying, or fall back to Claude directly and note \"independence reduced for this pass\" "
        "(model independence lost, context independence kept).\n"
        "</mh-codex-quota-advisory>"
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": context,
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
