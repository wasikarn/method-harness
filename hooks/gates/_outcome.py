#!/usr/bin/env python3
# Validator-outcome journal (GH #994): one row per Rule 13 validator verdict, written by
# subagent-verdict-gate.py on the allow path as well as the block path, so the first-pass
# rate and the rounds needed can be measured. Counts and booleans only: never a finding's
# text, a command, a path or any prompt text. A file of its own (validator-outcomes.jsonl);
# gate-decisions.jsonl stays non-allow only by design (see _journal.py).
#
# A module of its own, not part of _journal.py, on purpose: every gate imports _journal.py, so
# a change there changes the closure of every replay-supported gate (scripts/_lib/replay-check.sh)
# and demands a whole-pool replay for each. Only the verdict gate imports this one.
#
# Same safety as journal(): must NEVER affect the calling gate's verdict or exit code; every
# failure is swallowed. The HOME guard, the symlink refusal and the version read are repeated
# from _journal.py on purpose: keep them in sync, a fix to one must be made in both.
import json
import os


def journal_outcome(event, agent_type, session_id, verdict, flaws, denied):
    try:
        path = os.environ.get("MH_VALIDATOR_OUTCOMES_PATH")  # test-layer override
        if not path:
            home = os.environ.get("HOME")
            if not home or not os.path.isabs(home):
                return  # never resolve into the current working directory
            path = os.path.join(home, ".local", "share", "kbg", "metrics", "validator-outcomes.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.islink(path):
            return
        from datetime import datetime, timezone
        mh_version = None
        try:
            with open(os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", "/nonexistent"),
                                   ".claude-plugin", "plugin.json")) as pf:
                mh_version = json.load(pf).get("version")
        except Exception:
            pass

        def count(key):
            v = verdict.get(key)
            return len(v) if isinstance(v, list) else 0

        row = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "event": event,
            "agent_type": agent_type if isinstance(agent_type, str) else None,
            "session_id": session_id if isinstance(session_id, str) else None,
            "mh_version": mh_version,
            "pass": verdict.get("pass"),
            "findings": count("findings"),
            "checked": count("checked"),
            "scope_ok": verdict.get("scope_ok") if isinstance(verdict.get("scope_ok"), bool) else None,
            "unexpected": count("unexpected_files"),
            "flaws": flaws,
            "denied": denied,
        }
        with open(path, "a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:
        pass
