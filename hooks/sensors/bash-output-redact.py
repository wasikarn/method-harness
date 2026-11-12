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
    # Output text glues tokens to word characters far more often than source files do
    # (a JSON-escaped newline before a token, a KEY_ prefix, a `_old` suffix), so drop the
    # gate's word boundary at both ends: over-redacting output is cheaper than leaking a token.
    edge = "\\b"
    patterns = []
    for label, p, chk in ns["PATTERNS"]:
        src = p.pattern
        src = src[len(edge):] if src.startswith(edge) else src
        src = src[:-len(edge)] if src.endswith(edge) else src
        patterns.append((label, re.compile(src, p.flags), chk))
    return patterns, ns["is_placeholder"]


# The gate's Private key pattern only has to detect a key, so it stops at the first
# body line. Redaction has to take the whole block: every body line and the END line, or,
# when the output was cut off, every body line there is. It needs a body line under the
# header (16+ base64 characters; the gate asks for 40): a header alone is text about keys, and
# taking everything after it erased the rest of a grep or cat of this repo's own tests.
# A line break is a real one or a JSON-escaped one, since keys also arrive inside JSON strings.
_NL = r"[ \t]*(?:\\r\\n|\\n|\r?\n)"
_B64 = r"[A-Za-z0-9+/=]"
_END = r"-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"
PEM_BLOCK = re.compile(
    r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----" + _NL
    + r"(?:[A-Za-z0-9-]+:[^\n\\]*" + _NL + r")*(?:" + _NL + r")*"
    + _B64 + r"{16,}"
    + r"(?:(?:" + _NL + r")+" + _B64 + r"+(?=" + _NL + r"|[ \t]*\Z))*"
    + r"(?:(?:" + _NL + r")+" + _END + r")?")

# A pattern whose every match holds a fixed marker is skipped when the text lacks the marker.
# Without its leading word boundary the OpenAI pattern starts at every `sk-` inside a word and
# rescans the run each time: 400 KB of "risk-" took 33 s, past the hook's timeout.
REQUIRED_TEXT = {"OpenAI": "T3BlbkFJ"}


def redact(text, patterns, is_placeholder):
    text, hits = PEM_BLOCK.subn("[REDACTED:Private key]", text)
    for label, pattern, has_placeholder_check in patterns:
        if label in REQUIRED_TEXT and REQUIRED_TEXT[label] not in text:
            continue
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
    if not isinstance(d, dict):
        sys.exit(0)
    name = d.get("tool_name")
    is_mcp = isinstance(name, str) and name.startswith("mcp__")
    if name != "Bash" and not is_mcp:
        sys.exit(0)
    tr = d.get("tool_response")
    # Bash: {stdout, stderr, ...}. MCP: a list of content blocks (probed 2026-10-22);
    # only text blocks are rewritten, any other shape passes through untouched.
    if not (isinstance(tr, list) if is_mcp else isinstance(tr, dict)):
        sys.exit(0)
    patterns, is_placeholder = load_secret_scan()
    total = 0
    if isinstance(tr, list):
        out = []
        for blk in tr:
            if isinstance(blk, dict):
                blk = dict(blk)
                # text blocks carry "text"; an embedded resource block carries "resource": {"text": ...}
                holders = [blk]
                if isinstance(blk.get("resource"), dict):
                    blk["resource"] = dict(blk["resource"])
                    holders.append(blk["resource"])
                for h in holders:
                    if isinstance(h.get("text"), str) and h["text"]:
                        h["text"], n = redact(h["text"], patterns, is_placeholder)
                        total += n
            out.append(blk)
        field = "updatedMCPToolOutput"
    else:
        out = dict(tr)
        for key in ("stdout", "stderr"):
            val = tr.get(key)
            if isinstance(val, str) and val:
                out[key], n = redact(val, patterns, is_placeholder)
                total += n
        field = "updatedToolOutput"
    if total:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", field: out}}))
    sys.exit(0)
except SystemExit:
    raise
except Exception as e:
    print(f"[mh:sensor] bash-output-redact: internal error, output left unredacted ({e})", file=sys.stderr)
    sys.exit(0)
