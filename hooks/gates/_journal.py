#!/usr/bin/env python3
# Gate-verdict journal, restored (2026-09-12) after commit 2cac98c8 deleted the
# central-dispatcher version (hooks/dispatch-pretooluse.py) without a replacement.
# Every gate imports this defensively -- see each gate's own `try: from _journal
# import journal / except Exception: def journal(*a, **k): pass` -- never a bare
# import, since irrecoverable.py's wrapper turns any non-{0,2} exit into a hard
# deny (irrecoverable.sh:36-39): an ImportError here must never become a
# machine-wide Bash lockout.
import json, os


def journal(gate_id, tool_name, decision, session_id=None, rule=None, command=None, count=None):
    # Non-allow verdicts only ("ask"/"deny", plus secret-scan.py's own
    # "allow-suppressed" for same-line-marker-suppressed matches, one row per
    # call with count=N, GH #378, and a shadow
    # rule's "would_deny"/"would_ask", GH #337) -- matches
    # the actual need ("how often did gate X block/ask") and avoids the
    # write-rate of logging every allow. Must NEVER affect the calling
    # gate's own exit code or verdict: every failure mode below is
    # swallowed silently.
    try:
        override = os.environ.get("MH_GATE_JOURNAL_PATH")  # test-layer override,
        if override:                                        # same naming precedent
            path = override                                 # as cost-report's
        else:                                                # MH_COSTS_FILE
            home = os.environ.get("HOME")
            if not home or not os.path.isabs(home):
                # Unset/relative HOME must never resolve into the current
                # working directory -- this exact bug once wrote
                # gate-decisions.jsonl into this repo's own tree (2026-08-28;
                # see .gitignore's ".local/" comment and CHANGELOG.md).
                return
            path = os.path.join(home, ".local", "share", "kbg", "metrics", "gate-decisions.jsonl")
        log_dir = os.path.dirname(path)
        os.makedirs(log_dir, exist_ok=True)
        if os.path.islink(path):
            # Refuse to append through a symlink -- same hardening
            # cost-tracker.sh applies to costs.jsonl.
            return
        from datetime import datetime, timezone  # lazy: irrecoverable.py runs
        mh_version = None                          # on every Bash call and its
        try:                                        # .sh wrapper exists to dodge
            plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "/nonexistent")
            with open(os.path.join(plugin_root, ".claude-plugin", "plugin.json")) as pf:
                mh_version = json.load(pf).get("version")
        except Exception:
            pass
        row = {                                   # cold-start
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "id": gate_id,
            "tool_name": tool_name,
            "decision": decision,
            "session_id": session_id,
            "mh_version": mh_version,
        }
        # GH #337: the rule id of a gate's pattern rule, and for a shadow rule's
        # "would_deny"/"would_ask" row a sample of the command; absent otherwise.
        if rule is not None:
            row["rule"] = rule
        if command is not None:
            row["command"] = command
        if count is not None:  # GH #378: matches this one row stands for
            row["count"] = count
        with open(path, "a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:
        pass


def journal_outcome(event, agent_type, session_id, verdict, flaws, denied):
    # GH #994: one row per Rule 13 validator verdict, allow path included, so the
    # first-pass rate and the rounds needed can be measured. Counts and booleans
    # only: never a finding's text, a command, a path or any prompt text. A
    # separate file from gate-decisions.jsonl (that one is non-allow only by
    # design). Same safety as journal(): must NEVER affect the calling gate's
    # verdict or exit code, every failure is swallowed.
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
