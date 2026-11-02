#!/usr/bin/env python3
import json, os, re, sys
from collections import Counter

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

GATE_ID = "gate:write:test-integrity"

def emit_ask(reason, tool_name, session_id):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    journal(GATE_ID, tool_name, "ask", session_id)

# Real test-root shapes only — not a bare "test"/"spec" substring, which
# false-positived on spec-miner.md, anything containing "specific"/"inspect",
# and 67 tracked-file path matches total (found by the adversarial plan
# review that sank the original any-substring design).
PATH_RE = re.compile(
    r"(^|/)tests?/"
    r"|(^|/)test_[^/]+\.py$"
    r"|_test\.[^/]+$"
    r"|\.test\.[^/]+$"
    r"|\.spec\.[^/]+$",
    re.IGNORECASE,
)

# This repo's actual assertion idiom is the shared check() helper
# (tests/hooks/*.sh: `check "desc" "$ok"`), not assert/expect — checked
# against this repo's own test files before writing this pattern, per the
# plan's own instruction not to assume a vocabulary that is not actually in
# use here. Also covers pytest, jest/vitest `expect(`/`toThrow`, Go `t.Fatal*`, and chai `should`.
ASSERT_RE = re.compile(r"\bcheck\s*\"|\bassert\b|\bself\.assert|\bpytest\.raises\b|\bpytest\.fail\b|\bexpect\s*\(|\btoThrow\b|\bt\.(Fatal|Error|Fail)\w*\(|\.should\b")
SKIP_RE = re.compile(r"#\s*SKIP:|@pytest\.mark\.(skip|xfail)|\.skip\s*\(|\bxit\s*\(|\bit\.skip\s*\(", re.IGNORECASE)
# Bash has no marker-string idiom for disabling a line the way pytest/jest do
# -- it disables via control flow instead. `if`/`elif`/`while` opening on a
# bare false/0, or a bracket/test numeric comparison that's statically
# false, all fully neuter a kept assertion while leaving the assertion's
# own line text -- and the diff -- byte-identical, so SKIP_RE alone misses
# every one of them. Deliberately excludes `[ 0 ]`/`[[ false ]]`-style
# single-operand tests: those are non-empty-string checks and evaluate TRUE
# in bash (verified live), so matching them would be a false positive.
DEAD_KEYWORD_RE = re.compile(
    r"^\s*(if|elif|while)\s*\(?\s*(false|0)\b", re.IGNORECASE
)
DEAD_NUMERIC_RE = re.compile(
    r"^\s*(?:if|elif|while)\s*(?:\[+|test\s+)\s*(\d+)\s*(-eq|-ne)\s*(\d+)\b",
    re.IGNORECASE,
)
# A kept assertion can also be hidden by relocating its own line text into
# an inert region instead of wrapping it in a false conditional -- a
# HEREDOC body, or bash's "colon-quoted string" no-op-comment idiom
# (`: '...'`). Both are stripped before the line-scan below sees them,
# UNLESS the heredoc feeds an interpreter (bash/python/etc), in which case
# its body really does execute and must stay scannable -- same
# interpreter distinction irrecoverable.sh already uses for
# its own heredoc handling, ported rather than reinvented (deep-audit
# 2026-08-28).
SQ = chr(39)
_HEREDOC_RE = re.compile(r"<<(-)?\s*([" + SQ + r"\"]?)([^\s" + SQ + r"\"]+)\2")
_INTERPRETER_RE = re.compile(r"\b(bash|sh|zsh|dash|ksh|python3?|python2|perl|ruby|node|nodejs|osascript)\b")

def _strip_heredocs(text):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = _HEREDOC_RE.search(line)
        i += 1
        if not m:
            continue
        if _INTERPRETER_RE.search(line[:m.start()]):
            continue
        strip_tabs, delim = bool(m.group(1)), m.group(3)
        body_start, found = i, False
        while i < len(lines):
            body_line = lines[i].lstrip("\t") if strip_tabs else lines[i]
            i += 1
            if body_line == delim:
                found = True
                break
        if not found:
            out.extend(lines[body_start:i])
    return "\n".join(out)

_COLON_NOOP_OPEN_RE = re.compile(r"^\s*:\s*([" + SQ + r"\"])")

def _strip_colon_noop(text):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        m = _COLON_NOOP_OPEN_RE.match(line)
        i += 1
        if not m:
            out.append(line)
            continue
        out.append(line)
        quote = m.group(1)
        if quote in line[m.end():]:
            continue  # closed on the same line -- no block to skip
        while i < len(lines) and quote not in lines[i]:
            i += 1
        if i < len(lines):
            i += 1  # consume the closing-quote line too
    return "\n".join(out)

def _inert(text):
    return _strip_colon_noop(_strip_heredocs(text))

def assertion_lines(text):
    return Counter(ln.strip() for ln in _inert(text).splitlines() if ASSERT_RE.search(ln))

def skip_lines(text):
    return Counter(ln.strip() for ln in _inert(text).splitlines() if SKIP_RE.search(ln))

def dead_cond_lines(text):
    out = Counter()
    for raw in _inert(text).splitlines():
        ln = raw.strip()
        if DEAD_KEYWORD_RE.search(ln):
            out[ln] += 1
            continue
        m = DEAD_NUMERIC_RE.search(ln)
        if m:
            a, op, b = int(m.group(1)), m.group(2), int(m.group(3))
            is_dead = (op == "-eq" and a != b) or (op == "-ne" and a == b)
            if is_dead:
                out[ln] += 1
    return out

# The final `[ "$fail" -eq 0 ]` (or `[[ ]]`) line is what turns an
# accumulated fail count into the script's real exit code -- this
# repo's own test files, this gate's own test included, all use it.
# Deleting it (or leaving check() itself untouched) silently disables a
# test file's ability to ever fail CI, invisible to a call-site diff
# (deep-audit 2026-08-28).
EXIT_GATE_RE = re.compile(r"^\[\[?\s*\"?\$\{?fail\}?\"?\s*-eq\s*0\s*\]\]?")

def exit_gate_lines(text):
    return Counter(ln.strip() for ln in _inert(text).splitlines() if EXIT_GATE_RE.match(ln.strip()))

# Redefining the check() oracle itself is a total gate defeat, not a single
# skipped assertion -- call sites stay byte-identical, only the helper's
# own body changes, which ASSERT_RE's call-site-only pattern cannot see
# (deep-audit 2026-08-28, confirmed live). Compares the function's full
# body text, not just its definition line, so a reformatted-but-unchanged
# body does not false-positive.
#
# 2026-09-20 audit: the single-regex version above (`.*?` non-greedy up to
# the first bare "}" line) was defeatable two ways, both confirmed live:
# (1) a SECOND `check(){...}` definition appended after the real one --
# bash executes whichever was defined most recently, but `.search()` only
# ever sees the FIRST match, so a shadowing no-op redefinition was invisible.
# (2) a decoy nested `{ ... }` block inside the real body (e.g.
# `if ...; then { ...; }; fi`) whose own closing `}` sits on its own line --
# the non-greedy capture stopped THERE, hiding a real weakening placed
# after it in the same function. Fix: a brace-depth-aware scan (not a
# single regex) that finds each `check ( ) {` opening, then counts `{`/`}`
# to its real matching close, and returns the LAST such definition (bash's
# own resolution order) instead of the first.
#
# 2026-09-21 deep-audit: the line-start-only `check() {` anchor missed three
# spellings real bash honors -- `function check {` (no parens), `check() (`
# (subshell body, closed by ")") and a mid-line `true; check() {` -- so a
# shadowing no-op in any of them was invisible. group(1) is the opener; the
# scan below counts its matching pair. Preceded by line start or a
# separator/grouping char, never mid-word.
FUNC_OPEN_RE = re.compile(
    r"(?:^|[;&|(){}])\s*(?:function\s+check\s*(?:\(\s*\))?|check\s*\(\s*\))\s*([{(])",
    re.MULTILINE,
)

# 2026-09-20: extracted to a shared hooks/gates/_quotemask.py after this
# function and subagent-git-guard.py's identical _mask_quotes drifted into
# byte-for-byte copies that independently missed, then independently fixed,
# the same "#"-comment bug (deep-audit fix-round 3: a comment apostrophe
# before a real assertion opened an unterminated fake quote span, masking
# the real closing brace away -- a real weakening payload slipped through
# with no ask). Defensive import, same posture as _journal.py -- the
# fallback is the same inline copy this file carried before extraction.
try:
    from _quotemask import mask_quotes as _mask_quotes_bash
except Exception:
    def _mask_quotes_bash(s):
        def _back(k, blanks):
            # GH #833: the index of the char bash reads before s[k] (-1 at the start) and whether a backslash escapes it,
            # stepping over line continuations (an odd backslash run, then a newline) and, with blanks, unescaped blanks
            k -= 1
            while k >= 0:
                r = k - 1
                while r >= 0 and s[r] == "\\":
                    r -= 1
                if s[k] == "\n" and (k - 1 - r) % 2 == 1:
                    k -= 2
                elif blanks and s[k] in " \t" and (k - 1 - r) % 2 == 0:
                    k -= 1
                else:
                    return k, (k - 1 - r) % 2 == 1
            return k, False

        def _cmd_word(i, word, after, leads):
            # GH #833: whether s[i:] starts the reserved word `word` where bash reads it: at the start, after a char in
            # after, or after a word in leads; a blank, a separator or the end follows it
            if not s.startswith(word, i) or s[i + len(word):i + len(word) + 1] not in ("", " ", "\t", "\n", ";", "&", "|", ")"):
                return False
            k, e = _back(i, True)
            if k < 0 or not e and s[k] in after:
                return True
            for w in leads if not e else ():
                j = k + 1 - len(w)
                if j >= 0 and s.startswith(w, j) and (j == 0 or s[j - 1] in " \t\n;&|("):
                    if w != "in":
                        return True
                    m = _back(j, True)[0]  # `in` leads only as `case WORD in`, never as an argument (`echo in esac`)
                    while m >= 0 and s[m] not in " \t\n":
                        m -= 1
                    m = _back(m + 1, True)[0]
                    return s.endswith("case", 0, m + 1) and (m < 4 or s[m - 4] in " \t\n;&|(")
            return False

        out = []
        pad = {}  # GH #306: out index -> blank pairs to put in front of that piece
        word_start = 0
        ng = 0  # GH #833: how many entries of parens are True
        ie = -1  # GH #833 review 3: end of the unsure line, where quotes and "<" are inert
        unsure = -2  # GH #833 review 2: index in s of the last ")" read while a case marker was on top
        parens = []  # GH #820 item 5: per open unquoted "(", whether it is glued ($( <( >( =()
        i, n = 0, len(s)
        at_word_start = True
        while i < n:
            c = s[i]
            if c == "#" and unsure >= 0 and _back(i, False)[0] == unsure:
                # GH #833 review 2/3: as a comment the line hides nothing below it, and as a word a quote or "<<" in it
                # could; so it is read as a word, but up to its end (ie) no quote opens and each "<" masks to Q
                ie = s.find("\n", i)
                ie = n if ie < 0 else ie
                out.append(c)
                i += 1
                at_word_start = False
                continue
            if c == "#" and at_word_start:
                while i < n and s[i] != "\n":
                    out.append(" "); i += 1
                continue
            if c == "'" and i >= ie:
                out.append(" "); i += 1
                while i < n and s[i] != "'":
                    out.append("Q"); i += 1
                if i < n:
                    out.append(" "); i += 1
                at_word_start = False
            elif c == "$":  # GH #161: ANSI-C $'...', backslash escapes the next char; only the last "$" of an odd run opens it ("$$" is the PID)
                j = i
                while j < n and s[j] == "$":
                    out.append("$"); j += 1
                if (j - i) % 2 == 0 or j >= n or s[j] != "'" or j < ie:
                    i = j; at_word_start = False
                    continue
                out[-1] = " "; out.append(" "); i = j + 1
                while i < n and s[i] != "'":
                    if s[i] == "\\" and i + 1 < n:
                        out.append("Q"); out.append("Q"); i += 2
                    else:
                        out.append("Q"); i += 1
                if i < n:
                    out.append(" "); i += 1
                at_word_start = False
            elif c == '"' and i >= ie:
                out.append(" "); i += 1
                while i < n and s[i] != '"':
                    if s[i] == "\\" and i + 1 < n:
                        out.append("Q"); out.append("Q"); i += 2
                    else:
                        out.append("Q"); i += 1
                if i < n:
                    out.append(" "); i += 1
                at_word_start = False
            elif c == "\\":  # GH #157 sibling: an odd backslash run escapes a following quote (literal, not a span)
                j = i
                while j < n and s[j] == "\\":
                    j += 1
                if (j - i) % 2 == 1 and j < n and s[j] == "\n":  # GH #286: odd run + newline = line continuation, the shell deletes the pair
                    if j - i > 1:
                        out.append("\\" * (j - i - 1)); at_word_start = False
                    i = j + 1
                    if i < n and s[i] not in set(" \t\n;&|()") and word_start < len(out):
                        pad[word_start] = pad.get(word_start, 0) + 1  # GH #306: joins the word; blanks go to its front
                    else:
                        out.append("  ")  # GH #306: a blank, separator or the end follows: nothing glues
                    continue
                out.append("\\" * (j - i))
                if (j - i) % 2 == 1 and j < n and s[j] in "'\"$":  # an escaped "$" is literal too, never an ANSI-C opener
                    out.append("Q"); j += 1
                elif (j - i) % 2 == 1 and j < n and s[j] in " \t\n;&|()":
                    out.append(s[j]); j += 1  # an escaped blank or separator is part of its word: a "#" after it is no comment
                i = j
                at_word_start = False
            else:
                if c == "c" and at_word_start and _cmd_word(i, "case", ";&|()\n", ("then", "do", "else", "elif", "if", "while", "until", "{", "!", "time")):
                    parens.append("c")  # GH #833: a case pattern's ")" closes nothing until its esac
                elif c == "e" and parens and parens[-1] == "c" and _cmd_word(i, "esac", ";&)\n", ("in", "}", "fi", "done", "esac")):
                    parens.pop()
                out.append("Q" if i < ie and c in "'\"<" else c); i += 1
                at_word_start = c in set(" \t\n;&|()")
                if at_word_start:
                    word_start = len(out)
                if c == "(":
                    k, e = _back(i - 1, False)  # GH #833: extglob @( !( ?( *( +( glue as $( does
                    parens.append(k >= 0 and not e and s[k] in "$<>=@!?*+")
                    ng += parens[-1]
                elif c == ")" and parens and parens[-1] == "c":
                    if ng:  # GH #833 fail safe: a pattern or the real closer; a "#" after it is read both ways
                        at_word_start, unsure = False, i - 1
                elif c == ")" and parens and parens.pop():
                    ng -= 1
                    at_word_start = False  # GH #820 item 5: $(..)# is one word, never a comment
        return "".join("  " * pad.get(k, 0) + p for k, p in enumerate(out))

def check_helper_body(text):
    # ponytail: still not a full shell tokenizer (no backtick/$()-aware
    # nesting for braces inside command substitutions). No bypass via that
    # narrower path is demonstrated; widen further if one is.
    masked = _mask_quotes_bash(text)
    last = None
    for m in FUNC_OPEN_RE.finditer(masked):
        opener = m.group(1)
        closer = "}" if opener == "{" else ")"
        depth, i, start = 1, m.end(), m.end()
        while i < len(masked) and depth > 0:
            if masked[i] == opener:
                depth += 1
            elif masked[i] == closer:
                depth -= 1
            i += 1
        if depth == 0:
            last = text[start:i - 1]
    return last

def weakened(old_text, new_text):
    removed_assert = assertion_lines(old_text) - assertion_lines(new_text)
    added_skip = skip_lines(new_text) - skip_lines(old_text)
    added_dead_cond = dead_cond_lines(new_text) - dead_cond_lines(old_text)
    removed_exit_gate = exit_gate_lines(old_text) - exit_gate_lines(new_text)
    helper_changed = check_helper_body(old_text) != check_helper_body(new_text)
    return (
        bool(removed_assert)
        or bool(added_skip)
        or bool(added_dead_cond)
        or bool(removed_exit_gate)
        or helper_changed
    )

def reason(path):
    return (
        "test-integrity: this edit to " + path + " appears to remove an "
        "assertion or add a skip/disable marker. If this is a legitimate "
        "test change, approve; if it is weakening a test to make a fix "
        "pass, write the fix instead (METHODOLOGY.md Rule 4)."
    )

try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "") or ""
    session_id = d.get("session_id")
    ti = d.get("tool_input")
    if not isinstance(ti, dict):
        sys.exit(0)

    path = ti.get("file_path") or ""
    if not path or not PATH_RE.search(path):
        sys.exit(0)

    if tool == "Edit":
        old_s, new_s = ti.get("old_string", ""), ti.get("new_string", "")
        if weakened(old_s, new_s):
            emit_ask(reason(path), tool, session_id)
        sys.exit(0)

    if tool == "Write":
        if not os.path.exists(path):
            sys.exit(0)  # new-file creation — no old side to weaken
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                old_text = f.read()
        except Exception:
            # 2026-09-20 audit: this used to be a silent `sys.exit(0)` (allow)
            # -- directly contradicting the outer handler seven lines below,
            # which fails toward asking on the identical class of problem
            # ("cannot classify this edit"). A permission error, a directory
            # at this path, or a TOCTOU race with the os.path.exists() check
            # above all landed here and let a Write that guts a test's
            # assertions through with zero signal -- exactly the case this
            # gate exists to catch (METHODOLOGY Rule 4). Match the outer
            # handler's posture instead of the exact-opposite one.
            emit_ask(
                "test-integrity: could not read the existing " + path +
                " to compare against this Write -- approve manually or deny.",
                tool, session_id,
            )
            sys.exit(0)
        new_text = str(ti.get("content", ""))
        if weakened(old_text, new_text):
            emit_ask(reason(path), tool, session_id)
        sys.exit(0)

    sys.exit(0)
except Exception:
    # Cannot confirm this edit did not weaken a test — fail toward asking,
    # same posture this gate takes on any other unclassifiable statement.
    # `tool`/`session_id` may be unbound here (json.load itself could have
    # raised) -- pass literals, never the enclosing-scope names, or a
    # NameError inside this handler would silently turn fail-toward-ask into
    # fail-open on exactly the malformed input this branch exists to catch.
    emit_ask("test-integrity: could not classify this edit to a test-shaped path; approve manually or deny.", None, None)
