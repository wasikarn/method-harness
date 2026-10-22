#!/usr/bin/env python3
import io, json, os, re, sys

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)  # GH #156: an oversized int literal must not crash json.load


def load_secret_scan():
    # Reuse the live PATTERNS and is_placeholder: run secret-scan.py with an empty
    # payload and read its globals (same approach as scripts/_lib/gate-differential.py).
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gates", "secret-scan.py")
    ns = {"__name__": "secret_scan_patterns", "__file__": path}
    saved = sys.stdin
    sys.stdin = io.StringIO("{}")
    try:
        with open(path) as f:
            exec(compile(f.read(), path, "exec"), ns)
    except SystemExit:
        pass
    finally:
        sys.stdin = saved
    return ns["PATTERNS"], ns["is_placeholder"]


def redact(text, patterns, is_placeholder):
    hits = 0
    for label, pattern, has_placeholder_check in patterns:
        def sub(m, label=label, check=has_placeholder_check):
            nonlocal hits
            if check and is_placeholder(m.group(1)):
                return m.group(0)
            hits += 1
            return f"[REDACTED:{label}]"
        text = pattern.sub(sub, text)
    return text, hits


try:
    d = json.load(sys.stdin)
    if d.get("tool_name") != "Bash":
        sys.exit(0)
    tr = d.get("tool_response")
    if not isinstance(tr, dict):
        sys.exit(0)
    patterns, is_placeholder = load_secret_scan()
    out, total = dict(tr), 0
    for key in ("stdout", "stderr"):
        val = tr.get(key)
        if isinstance(val, str) and val:
            out[key], n = redact(val, patterns, is_placeholder)
            total += n
    if total:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                                 "updatedToolOutput": out}}))
    sys.exit(0)
except SystemExit:
    raise
except Exception as e:
    print(f"[mh:sensor] bash-output-redact: internal error, output left unredacted ({e})", file=sys.stderr)
    sys.exit(0)
