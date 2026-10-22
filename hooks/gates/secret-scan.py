#!/usr/bin/env python3
import bisect, json, re, sys

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

GATE_ID = "gate:write:secret-scan"


def emit_ask(reason, tool_name, session_id):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    journal(GATE_ID, tool_name, "ask", session_id)


# Vendor-specific, high-confidence patterns only -- deliberately not generic
# entropy scanning (too noisy on base64 blobs / test fixtures). Every pattern
# has exactly ONE capture group around its variable/random portion, used by
# is_placeholder() below; the PEM pattern has none and is exempt from that
# check by construction (has_placeholder_check=False).
#
# Anthropic is deliberately wider than the current published gitleaks rule
# (32+ open-ended vs. a tighter exact format) -- a stated v1 tradeoff, recall
# over precision, backstopped by the placeholder/suppression layers below.
#
# Stripe covers test/live/prod (not just test/live -- an earlier draft of
# this gate wrongly assumed Stripe has no prod_ prefix).
PATTERNS = [
    ("AWS access/session key", re.compile(r"\b(?:AKIA|ASIA)([0-9A-Z]{16})\b"), True),
    ("Anthropic", re.compile(r"\bsk-ant-[a-z]{2,8}\d{2}-([A-Za-z0-9_-]{32,})\b"), True),
    ("OpenAI", re.compile(r"\bsk-(?:(?:proj|svcacct|admin)-)?([A-Za-z0-9_-]{20,}T3BlbkFJ[A-Za-z0-9_-]{20,})\b"), True),
    ("GitHub token", re.compile(r"\bgh[pousr]_([A-Za-z0-9]{36})\b"), True),
    ("GitHub fine-grained PAT", re.compile(r"\bgithub_pat_([A-Za-z0-9_]{82})\b"), True),
    ("GitLab PAT", re.compile(r"\bglpat-([A-Za-z0-9_-]{20,})\b"), True),
    ("HuggingFace", re.compile(r"\bhf_([A-Za-z0-9]{34,})\b"), True),
    ("Slack", re.compile(r"\bxox[baprs]-([0-9]{10,13}-[0-9]{10,13}(?:-[0-9]{10,13})?-[A-Za-z0-9]{24,34})\b"), True),
    ("Stripe secret/restricted", re.compile(r"\b(?:sk|rk)_(?:test|live|prod)_([A-Za-z0-9]{24,})\b"), True),
    ("Google API key", re.compile(r"\bAIza([0-9A-Za-z_-]{35})\b"), True),
    ("npm", re.compile(r"\bnpm_([A-Za-z0-9]{36})\b"), True),
    ("PyPI", re.compile(r"\bpypi-AgEIcHlwaS5vcmc([A-Za-z0-9_-]{50,})\b"), True),
    ("Private key", re.compile(
        r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[ \t]*\r?\n"
        r"(?:[A-Za-z0-9-]+:[^\n]*\r?\n)*\r?\n?[A-Za-z0-9+/=]{40,}"
    ), False),
]

SUPPRESS_MARKERS = ("gitleaks:allow", "pragma: allowlist secret")

# Published, vendor-documented example values only, in their CAPTURED-BODY
# form (i.e. with the fixed vendor prefix already stripped) -- never guessed.
EXAMPLE_TOKENS = {"IOSFODNN7EXAMPLE"}  # AWS's own docs: AKIAIOSFODNN7EXAMPLE


def is_placeholder(body):
    # Skip only a token whose variable portion is a canonical placeholder
    # shape: a published example, or >=90% one repeated-or-ascending-by-1
    # run. Deliberately NOT a generic word-substring check (your/fake/
    # sample/etc.) -- that was a real false-negative bypass (a real leaked
    # key containing one of those words, or a deliberately crafted one,
    # would have silently passed).
    if not body:
        return False
    if body in EXAMPLE_TOKENS:
        return True
    n = len(body)
    best = cur = 1
    for i in range(1, n):
        if body[i] == body[i - 1] or ord(body[i]) == ord(body[i - 1]) + 1:
            cur += 1
        else:
            cur = 1
        if cur > best:
            best = cur
    return (best / n) >= 0.90


def findings(text, tool_name, session_id):
    # Linear in the text: a rescan from the start (or across the whole line)
    # per match was quadratic, and 40,000 matches ran past the 8 s hook
    # timeout, which allows the write. Newline offsets are built once, each
    # match finds its line by bisect, and each line is checked for a
    # suppress marker once. Suppressed matches are journaled as one counted
    # row (GH #378): a row per match took 10.3 s for 199,999 of them.
    seen = []
    seen_keys = set()
    newlines = None
    line_suppressed = {}
    suppressed = 0
    for label, pattern, has_placeholder_check in PATTERNS:
        for m in pattern.finditer(text):
            if has_placeholder_check and is_placeholder(m.group(1)):
                continue
            if newlines is None:
                newlines = [n.start() for n in re.finditer("\n", text)]
            k = bisect.bisect_left(newlines, m.start())  # newlines before the match
            if k not in line_suppressed:
                line_start = newlines[k - 1] + 1 if k else 0
                line_end = newlines[k] if k < len(newlines) else len(text)
                line_suppressed[k] = any(text.find(marker, line_start, line_end) != -1
                                         for marker in SUPPRESS_MARKERS)
            if line_suppressed[k]:
                suppressed += 1
                continue
            line_no = k + 1
            key = (label, line_no)
            if key in seen_keys:
                continue
            seen_keys.add(key)
            seen.append(key)
    if suppressed:
        journal(GATE_ID, tool_name, "allow-suppressed", session_id, count=suppressed)
    return seen


def build_reason(path, hits):
    shown = hits[:5]
    extra = len(hits) - len(shown)
    lines = [f"{label} (line {line_no})" for label, line_no in shown]
    listing = "; ".join(lines)
    if extra > 0:
        listing += f"; plus {extra} more"
    return (
        "secret-scan: possible credential-shaped token(s) in " + path + " -- " +
        listing + ". If this is a real key, deny, move it to an env var or "
        "secret manager, and rotate it if it has been pasted or committed "
        "anywhere. If it is a fake fixture or an intentionally gitignored "
        "secrets file (e.g. .env), approve, or mark the line with "
        "gitleaks:allow / pragma: allowlist secret."
    )


try:
    try:
        d = json.load(sys.stdin)
    except (RecursionError, MemoryError):
        # Depth overflow: the payload cannot be checked, so ask. Other parse errors still allow below.
        emit_ask("secret-scan: payload nested too deep to parse, so this write was not checked; approve only if expected.", None, None)
        sys.exit(0)
    tool = d.get("tool_name")
    ti = d.get("tool_input")
    session_id = d.get("session_id")
    if not isinstance(ti, dict):
        sys.exit(0)

    if tool == "Write":
        text = ti.get("content")
    elif tool == "Edit":
        text = ti.get("new_string")
    else:
        sys.exit(0)

    if not isinstance(text, str) or not text:
        sys.exit(0)

    path = ti.get("file_path")
    if not isinstance(path, str) or not path:
        path = "(unknown path)"

    hits = findings(text, tool, session_id)
    if hits:
        emit_ask(build_reason(path, hits), tool, session_id)
    sys.exit(0)
except Exception as e:
    # Fail open: this gate's verdict is advisory on a write that was already
    # happening, and it runs on every Write/Edit in every host project --
    # never let an internal bug turn into an ask on every write everywhere.
    print(f"[mh:gate] secret-scan: internal error, allowing ({e})", file=sys.stderr)
    sys.exit(0)
