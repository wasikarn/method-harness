#!/usr/bin/env python3
import json, os, re, signal, sys

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

try:
    import _bracex
except Exception as _e:
    _bracex = None
    print(f"[mh:gate] subagent-git-guard: _bracex not importable ({_e}); a brace-hidden git command is not read",
          file=sys.stderr)

GATE_ID = "gate:bash:subagent-git-guard"

try:
    d = json.load(sys.stdin)
except (RecursionError, MemoryError):
    # Fail-closed: an extra key nested deep enough (~130k on Python 3.15, ~990 on <=3.11) overflows the decoder (RecursionError "Stack overflow ...
    # while decoding a JSON array") and would otherwise allow a subagent git stash below. Claude Code never
    # sends such a payload, so denying it for every session (main included) costs nothing real. _err is not
    # defined yet and os._exit(2) skips a shutdown flush, so a closed stderr cannot turn this into rc 1.
    try:
        print("[mh:gate] BLOCKED: PreToolUse payload nested too deep to parse -- failing closed",
              file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass
    journal(GATE_ID, None, "deny", None)
    os._exit(2)
except Exception as e:
    # Fail-safe = ALLOW for every other parse error (truncated or malformed JSON): it must not stall
    # every subagent Bash call. Depth overflow above is the one exception and denies.
    print(f"[mh:gate] subagent-git-guard: unparseable stdin, allowing ({e})", file=sys.stderr)
    sys.exit(0)

if not isinstance(d, dict):
    print("[mh:gate] subagent-git-guard: non-object payload, allowing", file=sys.stderr)
    sys.exit(0)

if d.get("tool_name") != "Bash":
    sys.exit(0)

# agent_id is present ONLY inside a subagent call. Presence, not truthiness --
# an empty-string or null agent_id is still the signal (same fix already
# applied to subagent-spawn-guard.py:38 (GH #154) and
# task-complete-separation.py:57 (GH #155); this gate predated both and was
# missed until the 2026-09-20 audit).
if "agent_id" not in d:
    sys.exit(0)

ti = d.get("tool_input")
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str):
    sys.exit(0)

# GH #469: the work budget below does not track wall time (an allowed shape took 7.1 s and a refused one
# 7.4 s at 40M, of the 8 s hook timeout; a timed-out hook allows), so a length cap in characters decides
# first, before the quote mask below runs (about 0.45 s per MB: a 20 MB command timed out into allow).
# It is NOT a time bound for shapes under the cap: cost follows `;` count x length, so a padded
# `eval sudo ` + 24 args + `;` x 270 (15947 chars) took 6.5 s at load 3.5 and 9.8 s at load 9.4.
# The deadline below bounds those shapes directly (see docs/reference/repo-gotchas.md, GH #469).
# MH_SGG_MAX_CMD_CHARS: test-layer override so stress rows over the cap still run the scan; a value that
# is not a positive integer keeps the cap.
try:
    _MAX_CMD_CHARS = int(os.environ.get("MH_SGG_MAX_CMD_CHARS", "16000"))
except ValueError:
    _MAX_CMD_CHARS = 16_000
if _MAX_CMD_CHARS < 1:
    _MAX_CMD_CHARS = 16_000
# GH #309: the brace-expanded reading is longer than the command (a chained range such as
# `mkdir -p out/{a..z}/{a..z}/{a..j}` is 67 KB), so it has its own cap, the main gate's. The raw
# command is already under _MAX_CMD_CHARS; the deadline and the work budget bound the time.
_MAX_VIEW_CHARS = 150_000
_brace_too_big = False

def clip(s):
    # Log-injection guard: a crafted command cannot forge/erase a [mh:gate] line.
    s = re.sub(r"[^\x20-\x7e]", "?", str(s))
    return s[:120]

agent_type = clip(d.get("agent_type") or "unknown")

def _err(msg):
    # A closed stderr (a harness that stopped reading it) must not turn a deny into exit 120: any exit
    # other than 0 or 2 lets the command run. The message is flushed here, so the deny paths below can
    # os._exit(2) without a shutdown flush that would raise again.
    try:
        print(msg, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass

# GH #469: a deadline of the gate's own. No length or work charge tracks wall time across shapes and
# load, and a hook that hits its 8 s timeout is ALLOWED, so deny at 5 s instead. A signal handler can
# fire anywhere (even in module-level work outside the try below), so it denies and exits itself.
# MH_SGG_DEADLINE_SECS: test-layer override; a value that is not a positive number keeps the default
# (0 would disarm the timer) and one past the 8 s hook timeout is clamped to 7 s (inf or 1e300 would
# overflow setitimer and crash the gate, which exits 1 and so allows); each says so on stderr.
# No SIGALRM on this platform: the work budget and length cap still apply.
_raw_deadline = os.environ.get("MH_SGG_DEADLINE_SECS", "5")
try:
    _v = float(_raw_deadline)
except ValueError:
    _v = 0.0
_DEADLINE_SECS = min(_v, 7.0) if _v > 0 else 5.0
if not _v > 0:
    _err(f"[mh:gate] subagent-git-guard: MH_SGG_DEADLINE_SECS {_raw_deadline!r:.40} is not a positive number; using 5 s")
elif _v > 7.0:
    _err(f"[mh:gate] subagent-git-guard: MH_SGG_DEADLINE_SECS {_raw_deadline!r:.40} is over the 8 s hook timeout; clamped to 7 s")

def _deadline_hit(signum, frame):
    # try/finally: a failed print (a closed stderr) must not skip the exit, or the scan unwinds and allows.
    try:
        _err(f"[mh:gate] BLOCKED: subagent ({agent_type}) command took longer than the gate's {_DEADLINE_SECS:g} s "
             f"time limit to check ({len(cmd)} characters); write it to a file with the Write tool and run "
             f"the file, or split it into smaller commands.")
        journal(GATE_ID, "Bash", "deny", d.get("session_id"))
    finally:
        os._exit(2)

try:
    signal.signal(signal.SIGALRM, _deadline_hit)
    signal.setitimer(signal.ITIMER_REAL, _DEADLINE_SECS)
except (AttributeError, ValueError, OSError):
    pass

# 2026-09-20: extracted to a shared hooks/gates/_quotemask.py after this
# function and test-integrity.py's identical _mask_quotes_bash drifted into
# byte-for-byte copies that independently missed, then independently fixed,
# the same "#"-comment bug (deep-audit 2026-09-20: an ordinary comment
# apostrophe before a real "git" command opened an unterminated fake quote
# span, masking the literal "git" anchor away -- a full gate bypass).
# Defensive import, same posture as _journal.py: an ImportError here must
# never become a machine-wide Bash lockout on this deny-tier gate, so the
# fallback is the same inline copy this file carried before extraction.
try:
    from _quotemask import mask_quotes as _mask_quotes
except Exception:
    def _mask_quotes(s, cuts=None):
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
        pad = {}  # GH #306, #833: out index -> blanks to put in front of that piece
        word_start = 0
        ng = 0  # GH #833: how many entries of parens are True
        ie = -1  # GH #833 review 3: end of the unsure line, where quotes and "<" are inert
        unsure = -2  # GH #833 review 2: index in s of the last ")" read while a case marker was on top
        au = False  # GH #833 review 9/10: every ")" after an unsure "#" is unsure too
        parens = []  # GH #820 item 5: per open unquoted "(", whether it is glued ($( <( >( =()
        i, n = 0, len(s)
        bt = False  # GH #842: inside an unquoted backtick substitution opened on this line
        bo = -1
        at_word_start = True
        while i < n:
            c = s[i]
            if c == "#" and unsure >= 0 and _back(i, False)[0] == unsure:
                # GH #833 review 2-10: as a comment it hides the rest of its line, and as a word what that line does
                # (parens, quotes, a case, an esac, a continuation) changes how all after it reads; neither is safe, so
                # from here to the end the state is unknown (ie = n): read as a word, but no quote or comment opens, each
                # "<" masks to Q, an inert quote mark is dropped, and every later ")" is unsure (au). Over-reading only.
                ie, au = n, True
                out.append(c)
                i += 1
                at_word_start = False
                continue
            if c == "#" and at_word_start and i >= ie:
                cut = bt
                while i < n and s[i] != "\n":
                    if cut and s[i] == "\\" and s[i + 1:i + 2] not in ("", "\n"):
                        out.append(" ")  # GH #842: an escaped char, a backtick too, does not end the substitution
                        i += 1
                    elif cut and s[i] == "`":
                        if cuts is not None:  # GH #842: the backtick ends the comment
                            cuts.append((bo, i))
                        cut = bt = False
                    out.append(" ")
                    i += 1
                continue
            if c == "'" and i >= ie:
                out.append(" "); i += 1
                cut = bt
                while i < n and s[i] != "'":
                    if cut and s[i] == "\\" and s[i + 1:i + 2] in ("`", "\\"):
                        out.append("Q"); i += 1
                    elif cut and s[i] == "`":
                        if cuts is not None:  # GH #842: the backtick ends it
                            cuts.append((bo, i))
                        cut = bt = False
                    elif s[i] == "\n":
                        cut = False
                    out.append("Q"); i += 1
                if i < n:
                    out.append(" "); i += 1
                at_word_start = False
            elif c == "$":  # GH #161: ANSI-C $'...', backslash escapes the next char; only the last "$" of an odd run opens it ("$$" is the PID)
                j = i
                while j < n and s[j] == "$":
                    out.append("$"); j += 1
                if (j - i) % 2 == 1 and i < j < ie and s[j] in "'\"":
                    out.pop()  # GH #833 review 5/6: an inert $'..' or $".." drops its $ as bash does (the blank goes to the word
                               # front); dash's $ + 'x' reading of $'..' is not kept on an inert line
                    pad[word_start] = pad.get(word_start, 0) + 1
                    i = j
                    continue
                if (j - i) % 2 == 0 or j >= n or s[j] != "'" or j < ie:
                    i = j; at_word_start = False
                    continue
                out[-1] = " "; out.append(" "); i = j + 1
                cut = bt
                while i < n and s[i] != "'":
                    if s[i] == "\\" and i + 1 < n:
                        out.append("Q"); out.append("Q"); i += 2
                    else:
                        if cut and s[i] == "`":
                            if cuts is not None:  # GH #842: the backtick ends it
                                cuts.append((bo, i))
                            cut = bt = False
                        elif s[i] == "\n":
                            cut = False
                        out.append("Q"); i += 1
                if i < n:
                    out.append(" "); i += 1
                at_word_start = False
            elif c == '"' and i >= ie:
                out.append(" "); i += 1
                cut = bt
                while i < n and s[i] != '"':
                    if s[i] == "\\" and i + 1 < n:
                        out.append("Q"); out.append("Q"); i += 2
                    else:
                        if cut and s[i] == "`":
                            if cuts is not None:  # GH #842: the backtick ends it
                                cuts.append((bo, i))
                            cut = bt = False
                        elif s[i] == "\n":
                            cut = False
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
                        pad[word_start] = pad.get(word_start, 0) + 2  # GH #306: joins the word; blanks go to its front
                    else:
                        out.append("  ")  # GH #306: a blank, separator or the end follows: nothing glues
                    continue
                out.append("\\" * (j - i))
                if (j - i) % 2 == 1 and j < n and s[j] in "'\"$":  # an escaped "$" is literal too, never an ANSI-C opener
                    out.append("Q"); j += 1
                elif (j - i) % 2 == 1 and j < n and s[j] in " \t\n;&|()`":  # GH #842: an escaped backtick opens nothing
                    out.append(s[j]); j += 1  # an escaped blank or separator is part of its word: a "#" after it is no comment
                i = j
                at_word_start = False
            else:
                if c == "c" and at_word_start and _cmd_word(i, "case", ";&|()\n", ("then", "do", "else", "elif", "if", "while", "until", "{", "!", "time")):
                    parens.append("c")  # GH #833: a case pattern's ")" closes nothing until its esac
                elif c == "e" and parens and parens[-1] == "c" and _cmd_word(i, "esac", ";&)\n", ("in", "}", "fi", "done", "esac")):
                    parens.pop()
                if i < ie and c in "'\"":
                    # GH #833 review 5: an inert quote mark is dropped as bash drops it, its blank put at the front of the
                    # word, so a quoted name still reads whole ("git" stash, g''it stash); from here on nothing opens (ie = n)
                    pad[word_start] = pad.get(word_start, 0) + 1
                    ie = n
                elif i < ie and c == "<":
                    out.append("Q")
                    ie = n
                else:
                    out.append(c)
                    if c == "`" and i >= ie:
                        bt, bo = not bt, i  # GH #842: bo is the index of the backtick that opened it
                    elif c == "\n":
                        bt = False  # GH #842: a substitution is tracked on its own line only
                i += 1
                at_word_start = c in set(" \t\n;&|()")
                if at_word_start:
                    word_start = len(out)
                if c == "(":
                    k, e = _back(i - 1, False)  # GH #833: steps over a continuation ($\<nl>()
                    g = k >= 0 and not e
                    parens.append("x" if g and s[k] in "@!?*+" else g and s[k] in "$<>=")  # GH #833 review 7: "x" is unsure
                    ng += parens[-1] is True
                elif c == ")" and parens and parens[-1] == "x":
                    # GH #833 review 7: an extglob group glues (shopt -s extglob), but with extglob off !( is a negated
                    # subshell and x+() f@() a function, where a "#" after ")" is a comment: read it both ways
                    parens.pop()
                    at_word_start, unsure = False, i - 1
                elif c == ")" and parens and parens[-1] == "c":
                    if ng:  # GH #833 fail safe: a pattern or the real closer; a "#" after it is read both ways
                        at_word_start, unsure = False, i - 1
                elif c == ")" and parens and parens.pop():
                    ng -= 1
                    at_word_start = False  # GH #820 item 5: $(..)# is one word, never a comment
                if au and c == ")":
                    unsure = i - 1
        return "".join(" " * pad.get(k, 0) + p for k, p in enumerate(out)) + " " * pad.get(len(out), 0)

# GH #317: outside quotes a shell drops a backslash before an ordinary character (`g\it stash` and
# `git re\set` run git), but the mask keeps it. _mask drops it inside each word for the anchor scans;
# the freed blanks go to the word's front, so every word still ends at the same offset (the shell-body
# lookup reads the raw command there). A pair stays as it is (`\\` is a literal backslash), and so
# does a backslash before a character it makes literal (`\{`, `A\=1`, `\*`): dropping it there would
# change what the word means. Kept out of _quotemask.py: the heredoc scans need its offsets.
_WORD_TOKEN_RE = re.compile(r"[^\s;&|()<>]+")
_ESC_PAIR_RE = re.compile(r"\\(.)")
_KEEP_ESCAPED = set("\\{}=#$'\"`~*?[]!")

def _drop_escapes(m):
    w = m.group()
    if "\\" not in w:
        return w
    u = _ESC_PAIR_RE.sub(lambda e: e.group(0) if e.group(1) in _KEEP_ESCAPED else e.group(1), w)
    return " " * (len(w) - len(u)) + u

# GH #344: a shell also removes the quotes inside a word, so `"git" stash`, `g'i't stash`, `git "stash"`
# and `"env" git stash` run git, but the mask turns the quoted letters into Q. A word made only of
# command-word characters and quoted runs of them (`$'..'` and `$".."` too) is joined back to its
# letters, blanks to its front so offsets hold, where the mask shows it outside every quote (each quote
# mark a blank, each quoted letter a Q). An escaped letter (`"g"\it`) is one more piece. A quoted `=` is
# a command name, not an assignment, so it is not a word character, and a message with a blank or
# separator in it never forms such a word, so `-m "fix; git reset"` stays masked. The candidates sit
# between separators and hold none, so one finditer is linear. The same pattern is _SPAWN_QWORD_RE in
# irrecoverable.py (a test checks they match).
# `$'list'` is `list` in bash, zsh and ksh but `$list` in dash, and `$"show"` is `$show` in dash and zsh,
# so the `$` pieces are read three ways: both joined (bash, ksh), only `$'..'` joined (zsh), neither (dash,
# develop's reading). Each later pass runs only when the ones before allowed, and any deny wins. Joining
# can only lower a verdict through the `stash list|show` carve-out, which is why the readings matter there.
_QWORD_RE = re.compile(r"(?<![^\s;&|()<>{])(?:[\w./-]|\\[\w./-]|\$?\"[\w./-]*\"|\$?'[\w./-]*')+(?![^\s;&|()<>}])")
_QPIECE_RE = re.compile(r"(\$?)([\"'])([\w./-]*)[\"']|\\([\w./-])|([\w./-])")

# GH #843: a line continuation inside such a word (`g\<nl>"it" stash`, `"g"\<nl>it stash`) is deleted by the
# shell, and the mask (GH #306) moves its two blanks to the front of the word, so the word's quoted pieces
# no longer sit at their raw offsets. A word with continuations is read by its own pattern (the pattern
# above must stay _SPAWN_QWORD_RE's twin): pairs at its front or end are blanks in place in the mask, every
# pair between moved two blanks to the word front, and the pieces are checked against the mask past them.
_nl_join = 0  # GH #843: 0 off (develop's reading); 1 the joined reading; 2 joined, dropping bogus spans (_nl_view)
_QWORD_NL_BODY = r"(?:[\w./-]|\\[\w./-]|\\\n|(?:\$(?:\\\n)*)?\"(?:[\w./-]|\\\n)*\"|(?:\$(?:\\\n)*)?'[\w./-]*')+(?![^\s;&|()<>}])"
_QWORD_NL_BODY_RE = re.compile(_QWORD_NL_BODY)
_QWORD_NL_RE = re.compile(r"(?<![^\s;&|()<>{])(?<!\\\n)(?:[\w./-]|\\[\w./-]|\\\n|(?:\$(?:\\\n)*)?\"(?:[\w./-]|\\\n)*\"|(?:\$(?:\\\n)*)?'[\w./-]*')+(?![^\s;&|()<>}])")
# Its pieces: a `$` (continuations may stand between it and its quote: $\<nl>'git' is $'git'), a quoted piece (inside "..", a continuation is deleted too: "g\<nl>it" is git), an
# escaped letter, a continuation outside quotes, a plain letter.
_QPIECE_NL_RE = re.compile(r"((?:\$(?:\\\n)*)?)(\"(?:[\w./-]|\\\n)*\"|'[\w./-]*')|\\([\w./-])|(\\\n)|([\w./-])")
_dollar_join = "'\""  # the `$` quote kinds joined in this pass
_dollar_joined = False  # a word with a `$` piece was joined, so the other readings differ

def _join_pieces(word, k0, masked):
    # The letters of `word` (no continuations in it) if the mask at k0 shows it outside every quote, else None.
    letters = []
    for p in _QPIECE_RE.finditer(word):
        k = k0 + p.start()
        if p.group(5):
            ok = masked[k] == p.group(5)
            letters.append(p.group(5))
        elif p.group(4):
            ok = masked[k:k + 2] == p.group()
            letters.append(p.group(4))
        elif p.group(1) and p.group(2) not in _dollar_join:
            ok = False
        else:
            d, body = len(p.group(1)), p.group(3)
            ok = (masked[k:k + d] in ("", " ", "$") and masked[k + d:k + d + 1] == " " and
                  masked[k + d + 1:k + d + 1 + len(body)] == "Q" * len(body) and masked[k + d + 1 + len(body):k + d + 2 + len(body)] == " ")
            letters.append(body)
        if not ok:
            return None
    return "".join(letters)

def _join_pieces_nl(pieces, k, masked):
    # The letters of _QPIECE_NL_RE pieces (no continuation outside quotes among them) if the mask from k
    # shows them outside every quote, else None. A quoted piece is masked as blank, one Q per char, blank.
    letters = []
    for p in pieces:
        t = p.group()
        if p.group(5):
            ok = masked[k:k + 1] == t
            letters.append(t)
        elif p.group(3):
            ok = masked[k:k + 2] == t
            letters.append(p.group(3))
        else:
            # The pairs between `$` and its quote moved to the word front in the mask (see the caller), so
            # the piece is masked as `$` (or the blank of a $'..' opener), then blank, one Q per char, blank.
            d, q = min(len(p.group(1)), 1), p.group(2)
            body = q[1:-1]
            ok = (not d or q[0] in _dollar_join) and masked[k:k + d] in ("", " ", "$") and \
                masked[k + d:k + d + len(q)] == " " + "Q" * len(body) + " "
            letters.append(body.replace("\\\n", "") if q[0] == '"' else body)
            k += d + len(q)
            if not ok:
                return None
            continue
        if not ok:
            return None
        k += len(t)
    return "".join(letters)

def _join_quoted_words(raw, masked):
    global _dollar_joined
    if len(raw) != len(masked) or ("'" not in raw and '"' not in raw):
        return masked
    reps = []  # (start, end, joined text), checked against the mask as it came in
    if _nl_join and "\\\n" in raw:
        cands = list(_QWORD_NL_RE.finditer(raw))
        # _QWORD_NL_RE starts no word right after a backslash-newline (that made a long continued run
        # quadratic), but one that is no continuation ends its line: an even backslash run (`a\\<nl>`) or a
        # comment's last `\` (the mask of that physical line alone blanks it; the whole mask cannot say,
        # since it moves a continuation's blanks to its word front). A word is tried there too.
        for q in (i for i in range(len(raw) - 1) if raw.startswith("\\\n", i)):
            r = q
            while r > 0 and raw[r - 1] == "\\":
                r -= 1
            ls = raw.rfind("\n", 0, q) + 1
            _scan_cost(q + 1 - ls)
            if (q - r) % 2 == 1 or _mask_quotes(raw[ls:q + 1])[-1:] == " ":
                # A match that runs through this pair (`# c\<nl>g\<nl>"it"`) is bogus: bash ends the word at
                # the real newline. It is dropped, and the word after the pair is tried on its own.
                if _nl_join == 2:  # its own reading: masking the line alone can misread one that starts in a quote
                    cands = [c for c in cands if not c.start() <= q < c.end() - 1]
                mm = _QWORD_NL_BODY_RE.match(raw, q + 2)
                if mm and not any(c.start() < mm.end() and mm.start() < c.end() for c in cands):
                    cands.append(mm)
        for m in cands:  # GH #843: only the words _QWORD_RE cannot read whole
            w = m.group()
            if "\\\n" not in w or ("'" not in w and '"' not in w):
                continue
            ps = list(_QPIECE_NL_RE.finditer(w))
            a, b = 0, len(ps)
            while a < b and ps[a].group(4):
                a += 1
            while b - 1 > a and ps[b - 1].group(4):
                b -= 1
            core = [p for p in ps[a:b] if not p.group(4)]
            # Blanks the mask moved to the word front, one pair each: every inner pair, and every trailing
            # pair but the last (a backslash follows it, so it glues); only the last trailing pair is in place.
            inner = 2 * (b - a - len(core)) + 2 * max(len(ps) - b - 1, 0) + \
                sum(len(p.group(1) or "") - 1 for p in core if p.group(1) and len(p.group(1)) > 1)
            tail = ps[-1].start() if b < len(ps) else len(w)
            # Leading pairs are in place, or (a comment that ends in `<blank>\`, which is no continuation)
            # are not pairs at all: read the word both with them and from after them.
            for lead in ((0, 2 * a) if a else (0,)):
                k0 = m.start() + lead
                front = 2 * a - lead + inner
                if masked[k0:k0 + front] != " " * front or masked[m.start() + tail:m.end()].strip():
                    continue
                j = _join_pieces_nl(core, k0 + front, masked)
                if j is not None:
                    _dollar_joined = _dollar_joined or any(p.group(1) for p in core)
                    reps.append((k0, m.end(), j))
                    break
    taken = list(reps)
    for m in _QWORD_RE.finditer(raw):
        if "'" not in m.group() and '"' not in m.group():
            continue
        if any(x < m.end() and m.start() < y for x, y, _ in taken):
            continue  # part of a word GH #843 already joined whole
        j = _join_pieces(m.group(), m.start(), masked)
        if j is not None:
            _dollar_joined = _dollar_joined or "$" in m.group()
            reps.append((m.start(), m.end(), j))
    if not reps:
        return masked
    out, last = [], 0
    for x, y, j in sorted(reps):
        out.append(masked[last:x]); out.append(" " * (y - x - len(j)) + j); last = y
    return "".join(out) + masked[last:]

# The whole command is masked again by _shell_bodies; on a 2 MB command each mask costs about 1 s.
_mask_memo = {}

def _mask(s):
    k = (_dollar_join, _nl_join, s)
    if k not in _mask_memo:
        _mask_memo[k] = _WORD_TOKEN_RE.sub(_drop_escapes, _join_quoted_words(s, _mask_quotes(s)))
    return _mask_memo[k]

masked = _mask(cmd) if len(cmd) <= _MAX_CMD_CHARS else ""  # over the cap: denied below, never scanned

# Anchor: "git" must sit at a real command-start (string/line start, |;&(, &&,
# ||, optional VAR=val chain, optional prefix wrapper(s), or a /path/git).
# re.MULTILINE so each line of a multi-line command anchors. Runs on the masked
# string, so `git commit -m "fix; git reset was wrong"` never anchors inside
# the quotes.
#
# 2026-09-20 audit: the old wrapper allowance (`sudo`/`xargs` only, one level)
# missed `env`/`command`/`nice` and a bare `\git` (backslash suppresses alias
# lookup; the command itself is unaffected) -- live-confirmed to still reach
# real git for a subagent. Fix: matched against a fixed wrapper-word list.
# `xargs` kept from the original list (this file never runs its own
# xargs-unwrap, so the anchor must still recognize it).
#
# 2026-09-20 fix-round 2 (compliance-audit): a first attempt bounded both
# chain depth and flags-per-wrapper at 3 to dodge the catastrophic-
# backtracking shape of `(?:(?:sudo|env|...)\s+(?:\S+\s+)*)*` (a wrapper word
# also matches the inner generic token, so the two `*`s compete for the same
# input) -- but that bound was itself a live-demonstrated gap (a 13-wrapper
# chain got through). The actual fix is to remove the ambiguity instead: the
# inner flag-scan excludes anything matching a wrapper word via a negative
# lookahead, so a token is always unambiguously "the next wrapper" or "a
# flag", never a choice between the two -- O(n), no backtracking, and both
# axes are genuinely unbounded again, matching irrecoverable.py's identical
# fix to its nested-spawn anchor.
#
# GH #213: the list gained exec/setsid/timeout/gtimeout/stdbuf/ionice (the same
# words as irrecoverable.py's PREFIX_WRAPPERS, which this file still types by
# hand), and a shell keyword may open the command position ("for i in 1; do git
# stash; done"). A wrapper word must be followed by whitespace in the lookahead
# too: with a bare \b a token that only STARTS with one ("timeout=30") is neither
# a wrapper nor an ordinary token, and the regex dead-ends.
_WRAPPER_WORDS = ("env", "command", "nohup", "nice", "time", "sudo", "doas", "xargs",
                  "exec", "setsid", "timeout", "gtimeout", "stdbuf", "ionice")
_KEYWORDS = ("!", "if", "elif", "then", "else", "do", "while", "until", "coproc")
# GH #320: a wrapper written as a path (`/usr/bin/env git stash`) runs the same program, so each
# wrapper word (and rtk, command and exec below) takes an optional directory prefix. The prefix is
# one plain word that never starts with `-` and holds no `=`, `<` or `>`: then a token is a path
# wrapper, a flag, an assignment or a redirection, never two of them, so no repeated group here can
# split a run of tokens two ways (that ambiguity is what made the old chain loops exponential).
_PATH = r"(?:(?!-)[^\s;&|()<>=]*/)?"
_WRAPPER_ALT = _PATH + r"(?:" + "|".join(_WRAPPER_WORDS) + r")(?=\s)"
_WRAPPER_PREFIX = r"(?:" + _WRAPPER_ALT + r"\s+(?:(?!" + _WRAPPER_ALT + r")\S+\s+)*)*"
# GH #248: the greedy walk above lands on the LAST target, so `time git stash; git status` anchored
# only the second `git`. The lazy twin (`*?`) lands on the FIRST target after the wrappers. It only
# runs as a last, extra pass, so it can only add anchors.
_WRAPPER_PREFIX_LAZY = r"(?:" + _WRAPPER_ALT + r"\s+(?:(?!" + _WRAPPER_ALT + r")\S+\s+)*?)*"
_KEYWORD_PREFIX = r"(?:(?:" + "|".join(re.escape(k) for k in _KEYWORDS) + r")\s+)*"
# Deep-audit 4: eval (its unquoted args are a command line), builtin and rtk run the command
# after them, but they are NOT in _WRAPPER_WORDS. That list drives the greedy argument walk
# above, which crosses `;` / `&&` / newlines to the LAST `git` and lets finditer resume after
# it, so a real `git stash` in an earlier statement was never tested (`eval true; git stash;
# git status`; time, timeout and env leaked this way until GH #245's overlapping scan). These words take
# their own bounded prefix instead: the word itself, `rtk`'s global flags and one runner verb
# with its flags, never an argument walk. It sits AFTER the wrapper walk, so the walk still
# behaves exactly as before for every old wrapper, and it can only add anchors.
# GH #273: eval joins its arguments into a command line, so `eval A=1 env git stash` runs git; the
# other three treat `A=1` as a command name. Only eval takes assignments.
# GH #520: an assignment value can be quoted or hold an escaped blank, and the quote mask shows a quoted
# span as blank + Q letters + blank (A="x y" is `A= QQQ `) and the word drop keeps `\ `, so the value is a
# run of: an escaped blank, a plain character, a lone backslash, or one masked quoted span. Each
# alternative starts with a different character class, so a run still splits one way only.
_ASSIGN_VALUE = r"(?:\\[ \t]|[^\s\\]|\\(?![ \t])|[ ]Q+[ ])*"
_ASSIGN_WORD = r"[A-Za-z_][A-Za-z0-9_]*=" + _ASSIGN_VALUE
_ASSIGN_RUN = r"(?:" + _ASSIGN_WORD + r"[ \t]+)*"
_EVAL_PASS = r"eval[ \t]+(?:--[ \t]+)?" + _ASSIGN_RUN
# GH #339: exec takes -c, -l and `-a NAME` (`eval exec -a x git stash` runs git). A flag holding an `a`
# takes the next word, one without takes none, so a token is read one way only.
_EXEC_FLAGS = r"(?:-[cl]*a[ \t]+\S+[ \t]+|-[cl]+[ \t]+)*"
_SHELL_PASS = (r"(?:" + _EVAL_PASS + r"|(?:builtin|" + _PATH + r"command)[ \t]+(?:--[ \t]+)?|" +
               _PATH + r"exec[ \t]+" + _EXEC_FLAGS + r"(?:--[ \t]+)?)")
_RTK_PREFIX = r"(?:" + _PATH + r"rtk[ \t]+(?:-\S+[ \t]+)*(?:(?:proxy|run|err|test|summary)[ \t]+(?:-\S+[ \t]+)*)?)"
_CHAIN_PREFIX = r"(?:" + _SHELL_PASS + r"|" + _RTK_PREFIX + r")*"
# GH #248: `{ git stash; }` -- a brace group opens a command position (`{` then blank).
# GH #273: a chain word may come BEFORE a wrapper (eval sudo git stash, rtk proxy time git stash).
# One optional leading run of the chain words that are NOT wrapper words (eval, builtin, rtk), taken
# only when a wrapper word follows it, covers it. command and exec are wrapper words, so the walk
# already takes them and what follows. Letting the leading run take them too made every split of a
# run a second parse (command x 700 before eval "git stash" took 8 s), and a chain/wrapper loop was
# exponential (sudo eval x 250 never finished). The lookahead makes the end of the run unique.
# The lookahead names the wrapper words minus command/exec: with them, `rtk exec git stash; git status`
# lost the anchor develop gave it through _CHAIN_PREFIX (deep-audit whole-picture pass). GH #307:
# command/exec are only stepped over (_LEAD_STEP) on the way to a real lead wrapper.
_LEAD_WRAPPER_ALT = _PATH + r"(?:" + "|".join(w for w in _WRAPPER_WORDS if w not in ("command", "exec")) + r")(?=\s)"
# GH #307: the lookahead may step over command/exec (with their flags) to reach a lead wrapper
# (`eval command env git stash`). Only the lookahead does: the run still ends at the same chain word, and
# the walk takes command/exec itself, so no second parse of any run appears. The stepped words are fixed
# words and `-flags`, disjoint from each other, so the scan is linear in the stepped span.
# GH #339: a step also takes exec's `-a NAME` (`eval A=1 exec -a x doas git stash`) and rtk runs after
# command/exec (`eval command rtk proxy nohup git stash`). rtk comes only after a command/exec word, never
# first, so it cannot split against the leading run's own rtk; every repeated piece starts with a
# different fixed word or a `-`, so the step stays linear.
_LEAD_STEP = (r"(?:" + _PATH + r"(?:command|exec)[ \t]+(?:-[cl]*a[ \t]+\S+[ \t]+|-(?![cl]*a[ \t])\S*[ \t]+)*" +
              _RTK_PREFIX + r"*)*")
_LEAD_CHAIN = (r"(?:(?:" + _EVAL_PASS + r"|builtin[ \t]+(?:--[ \t]+)?|" + _RTK_PREFIX + r")+(?=" + _LEAD_STEP + _LEAD_WRAPPER_ALT + r"))?")
# GH #285: a redirection (operator + its word) may sit before the command word and hid it
# (`</dev/null git stash`, `<<EOF git stash`); skipped like a VAR=val, in any mix with them.
_REDIR = r"(?:(?:\d+|\{\w+\})?(?:<<<?-?|&>>?|[<>]&|<>|>\||[<>]>?)[ \t]*[^\s;&|()<>]+[ \t]+)"
# GH #318: zsh also runs a brace group with no blank after `{` (`{git stash;}`); bash, dash and ksh
# read `{git` as a word. The Bash tool runs zsh, so a glued `{` opens a command position too (any
# deny wins) when it starts a word: zsh runs `(){git stash;}` and `{{git stash;};}`, but not
# `x{git stash;}`, `${git stash;}` or `{true;}{git stash;}`. `{` + blank keeps develop's reading.
def _cmd_start(wrapper_prefix):
    return (r"(?:^|[|;&(]|&&|\|\||\{(?=\s)|(?<![^\s;&|(){])\{)\s*" + _KEYWORD_PREFIX +
            r"(?:(?:" + _ASSIGN_WORD + r"\s+)|" + _REDIR + r")*" + _LEAD_CHAIN + wrapper_prefix + _CHAIN_PREFIX)
# GH #245: every anchor regex is scanned with overlapping matches, `(?=(...))`, read through
# m.end(1). The old wrappers' greedy argument walk (`time ls; git stash; git status`) crosses
# `;` / `&&` / newline to the LAST `git`, and a plain finditer resumed after that match, so the
# earlier statement was never checked. The zero-width scan tries every position, so each
# separator inside a walked span still anchors. At any position where finditer matched, the
# inner regex finds the same match, so this only adds checks, never drops one.
# The overlapping scan is quadratic on long padded commands, and a timed-out hook allows, so the
# plain scans (develop's exact behaviour, fast) run first and the overlapping pass only after
# both allowed: a command the plain scans deny is denied just as fast as before.
def _plain_and_overlapping(tail):
    pattern = _cmd_start(_WRAPPER_PREFIX) + tail
    return (re.compile(r"(" + pattern + r")", re.MULTILINE),
            re.compile(r"(?=(" + pattern + r"))", re.MULTILINE),
            re.compile(r"(?=(" + _cmd_start(_WRAPPER_PREFIX_LAZY) + tail + r"))", re.MULTILINE))

_GIT_WORD = r"\\?(?:\S*/)?git\b"
_ANCHOR_RES = _plain_and_overlapping(_GIT_WORD)
_LAZY = 2  # index of the lazy pass in _plain_and_overlapping's tuple
# `bash -c "<body>"` / `eval "<body>"`: the body is a quoted string, so the masked
# text hides it. The shell word is matched on the masked string (a real command,
# not text inside a message); the body is read from the raw command at the same
# offset (masking is 1:1) and checked as its own command line, one level deep.
# `rtk run [flags] "<body>"` and `rtk err|test|summary [flags] "<body>"` run their args through
# `sh -c` (irrecoverable.py, GH #216), so a quoted arg is a body too. Flags after the verb
# (`-c`, `--command`, `--command='...'`, `--skip-env`, `--ultra-compact`, a bare `--`) come
# before it. The string is quote-masked, so an opening quote is a blank there and a flag
# word ends at it: `--command='git stash'` leaves the quote for _QUOTED_RE.
# The flags after the verb may not hold `;`, `&` or `|`: this alternative can match on its own, and
# with `\S` it would swallow the next statement's separator (`rtk run -n||timeout 5 bash -c '...'`)
# so finditer resumed after it and never saw that statement's shell word.
_RTK_BODY = r"rtk[ \t]+(?:-\S+[ \t]+)*(?:run|err|test|summary)(?:[ \t]+-[^\s;&|]*)*"
_SHELL_RES = _plain_and_overlapping(
    r"\\?(?:\S*/)?(?:(?:bash|sh|zsh|dash|ksh)\s+(?:-\S+\s+)*?-[^\Wc]*c\w*|eval|" + _RTK_BODY + r")(?=\s)"
)
# GH #275: `-[^\Wc]*c\w*` is the same language as `-\w*c\w*` but splits at the FIRST `c` only; the old
# form retried every split of a long `-ccc...` token (quadratic, 60 KB ran past 20 s, a timeout allows).
# Masking blanks the quote characters, so the raw body is found by skipping
# whitespace from the end of the shell word.
# GH #306: `\\[\s\S]`, not `\\.`: a backslash-newline inside "..." is a continuation, and `.` stopped
# at it, so `bash -c "git \<nl>stash"` had no body at all. A continuation may also sit between the
# shell word and the quote (`bash -c\<nl> 'git stash'`): the mask blanks it, the raw text still has it.
_QUOTED_RE = re.compile(r'(?:\s|\\\n)*(?:"((?:[^"\\]|\\[\s\S])*)"|' + "'([^']*)')")
# Only stash/reset/clean (see header); read-only `stash list|show` carved out.
_DENY_SUBCMD_RE = re.compile(r"\s+(stash(?!\s+(list|show)\b)|reset|clean)\b")

# Git global flags walked past before the subcommand check, so `git -C /repo
# stash` / `git --no-pager clean` do not land the check on sub="-C".
_GIT_VALUE_GLOBALS = ("-C", "-c", "--git-dir", "--work-tree", "--config-env", "--namespace", "--attr-source")

# GH #276: the next git word in the same statement (matched at the offset of a non-flag token, so
# each hit moves forward).
_NEXT_GIT_RE = re.compile(r"[^;&|\n()]*?\s" + _GIT_WORD)
_FLAG_TOKEN_RE = re.compile(r"\s+(\S+)")
_FLAG_VALUE_RE = re.compile(r"\s+\S+")

def _skip_git_globals(s, i):
    # i is the offset right after the "git" anchor on the masked string. Returns the offset of the
    # first non-flag token's leading whitespace, so _DENY_SUBCMD_RE's \s+ still matches there.
    # GH #246: walk by offset, never re-slice the string per flag (quadratic on a long flag run).
    while True:
        m = _FLAG_TOKEN_RE.match(s, i)
        if not m:
            return i
        tok = m.group(1)
        if not tok.startswith("-"):
            return i
        if tok in _GIT_VALUE_GLOBALS:
            i = m.end()
            m2 = _FLAG_VALUE_RE.match(s, i)
            if m2:
                i = m2.end()
            continue
        i = m.end()  # any other flag, bare or combined: --git-dir=X, --no-pager, -p, ...

# GH #246: every anchor scan tries each command start (a separator or line start) and walks the
# rest of the string when a wrapper word or assignment follows, so the work grows like
# starts x length. `env ; ` x 5000 (30 KB) or 6000 bare newlines run past the 8 s hook timeout,
# and a timed-out hook allows: padding in front of a real `git stash` walked around the deny.
# Each scan charges that upper bound to one shared budget (bodies and all three passes add up) and a
# command over budget is denied, never scanned. Real subagent commands charge far less; only a
# rare huge script (about 16-23 KB, ~5e7 over six scans, measured at the old 60M; a 12.7 KB real command is refused at 40M) is refused.
# Deep-audit 5: a run of chain words (_CHAIN_PREFIX: eval/builtin/command/exec/rtk) after a wrapper
# is re-read from every walk position, so it costs about run x run per command start even with a
# single start (`true; ` + `command ` x 8000 before a `git stash` took 9 s). Each maximal run charges
# its length squared per start, plus one for the line start.
_WORK_BUDGET = 40_000_000  # was 45M, 60M before; at 45M the GH #307 shape was refused only after 7.0 s of the 8 s hook timeout (GH #469), 4.3 s at 40M
_work = 0
_CHAIN_RUN_RE = re.compile(r"(?<!\S)(?:" + _SHELL_PASS + r"|" + _RTK_PREFIX + r")+")

class _TooCostly(Exception):
    pass

def _charge(s):
    global _work
    starts = sum(s.count(c) for c in "\n;&|({")
    runs = sum((m.end() - m.start()) ** 2 for m in _CHAIN_RUN_RE.finditer(s))
    _work += starts * len(s) + (starts + 1) * runs
    if _work > _WORK_BUDGET:
        raise _TooCostly

def _violation(masked_cmd, overlap):
    _charge(masked_cmd)
    for m in _ANCHOR_RES[overlap].finditer(masked_cmd):
        pos = m.end(1)
        while True:
            pos = _skip_git_globals(masked_cmd, pos)
            dm = _DENY_SUBCMD_RE.match(masked_cmd, pos)
            if dm:
                return dm.group(1)
            # GH #276: the lazy pass lands on the first git word, which can be a wrapper's argument
            # (sudo -u git git stash); a later git word in the same statement may be the real one.
            # Offsets only, no re-slicing: each hit moves pos forward, so the walk is linear.
            nxt = _NEXT_GIT_RE.match(masked_cmd, pos) if overlap == _LAZY else None
            if not nxt:
                break
            pos = nxt.end()
    return None

# GH #327: eval and `sh -c` hand their argument text to a second parse, so a backslash pair that is a
# literal backslash after the first parse is an escape in the second (`eval g\\\it stash`,
# `bash -c "g\\it stash"`, `eval "git " stash`). _read_words does the first parse's quote removal: one
# word after -c, every word to the end of the statement after eval (joined with blanks, as eval does).
# That text is checked as a second body; the raw quoted body is still checked, so any deny wins. A
# `$(..)` or backtick span is copied as it is. `$'..'` is decoded the bash way (dash reads it as `$`
# plus a quoted word, which names no git). One linear pass, memoized, charged to the work budget.
_ANSI_ESC = {"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"'}
_STMT_END = frozenset(";&|\n<>()")

def _ansi_c(s, i, n):  # s[i] follows `$'`; returns (decoded text, index after the closing quote)
    out = []
    while i < n and s[i] != "'":
        if s[i] == "\\" and i + 1 < n:
            c = s[i + 1]
            if c in _ANSI_ESC:
                out.append(_ANSI_ESC[c]); i += 2; continue
            digits, lim = ("0123456789abcdefABCDEF", 2) if c == "x" else ("01234567", 3)
            j = k = i + 1 + (c == "x")  # the first digit: after `\x`, or right after `\` for octal
            while k < n and k - j < lim and s[k] in digits:
                k += 1
            if k > j:
                out.append(chr(int(s[j:k], 16 if c == "x" else 8) & 0xFF)); i = k; continue
            out.append(s[i:i + 2]); i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out), i + 1

def _read_words(s, i, all_words):
    """-> (words, end, new_sub). new_sub: a `$` or backtick came out of a quote or an escape, so the text
    may hold a substitution the raw scan never saw (a copied span is one it already saw)."""
    words, cur, n, new_sub = [], None, len(s), False
    while i < n:
        c = s[i]
        if c in " \t":
            if cur is not None:
                words.append("".join(cur)); cur = None
                if not all_words:
                    break
            i += 1; continue
        if c in _STMT_END:
            break
        if cur is None:
            cur = []
        if c == "\\":
            if i + 1 < n and s[i + 1] != "\n":
                cur.append(s[i + 1])
                new_sub = new_sub or s[i + 1] in "$`"
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(s[i + 1:j]); i, new_sub = j + 1, new_sub or "$" in cur[-1] or "`" in cur[-1]
        elif c == "$" and s.startswith("'", i + 1):
            text, i = _ansi_c(s, i + 2, n); cur.append(text)
            new_sub = new_sub or "$" in text or "`" in text
        elif c == '"' or (c == "$" and s.startswith('"', i + 1)):
            i += 1 if c == '"' else 2
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n and s[i + 1] in '$`"\\\n':
                    if s[i + 1] != "\n":
                        cur.append(s[i + 1])
                        new_sub = new_sub or s[i + 1] in "$`"
                    i += 2
                else:
                    cur.append(s[i]); i += 1
            i += 1
        elif c == "`" or (c == "$" and s.startswith("(", i + 1)):
            j, depth = (i + 1, 0) if c == "`" else (i + 2, 1)
            while j < n and (s[j] != "`" if c == "`" else depth):
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 2 if s[j] == "\\" else 1
            j = min(j + (c == "`"), n)
            cur.append(s[i:j]); i = j
        else:
            cur.append(c); i += 1
    if cur is not None:
        words.append("".join(cur))
    return words, i, new_sub

_reparse_memo = {}

def _bodies_at(raw_cmd, masked_cmd, m, for_subs=False):
    """The text a shell word at m hands to a second parse: the raw quoted body, then the GH #327 one.
    for_subs: the caller only wants substitutions, so the GH #327 body counts only when it can hold new ones."""
    global _work
    i, out = m.end(1), []
    q = _QUOTED_RE.match(raw_cmd, i)
    if q:
        out.append(q.group(1) if q.group(1) is not None else q.group(2))
    k = (raw_cmd, i)
    if k not in _reparse_memo:
        is_eval = masked_cmd.endswith("eval", 0, i)
        words, end, new_sub = _read_words(raw_cmd, i, is_eval)
        _work += end - i
        if _work > _WORK_BUDGET:
            raise _TooCostly
        _reparse_memo[k] = (" ".join(words) if is_eval else (words[0] if words else ""), new_sub)
    text, new_sub = _reparse_memo[k]
    if text and text not in out and (new_sub or not for_subs):
        out.append(text)
    return out

def _violation_in_bodies(raw_cmd, masked_cmd, overlap):
    _charge(masked_cmd)
    for m in _SHELL_RES[overlap].finditer(masked_cmd):
        for body in _bodies_at(raw_cmd, masked_cmd, m):
            hit = _violation_in_body(body, overlap)
            if hit:
                return hit
    return None

def _violation_in_body(body, overlap):
    mb = _mask(body)
    hit = _violation(mb, False) or (overlap and _violation(mb, overlap))
    if hit:
        return hit
    for v in _extra_views(body, mb):  # GH #843/#844: then the body read the other ways too
        if isinstance(v, _BodyView):  # read one level deep here, like develop's body check
            continue
        t, mt = v
        hit = _violation(mt, False) or (overlap and _violation(mt, overlap))
        if hit:
            return hit
    return None

def _view_violation(v, overlap):
    if isinstance(v, _BodyView):
        for body in v[2]:
            hit = _violation_in_body(body, overlap)
            if hit:
                return hit
        return None
    return _violation(v[1], overlap) or _violation_in_bodies(v[0], v[1], overlap)

# GH #274: the mask blanks everything inside "..." so `echo "$(git clean -fd)"` and backticks
# hid a real command. One linear pass over the raw command collects every $(...) / `...` body at
# any depth (a frame stack, so nesting costs no rescans); each body is then checked as its own
# command line. Single-quoted text is literal and skipped; an unterminated body runs to the end.
# The pass also knows what a naive bracket count gets wrong: a case pattern's `)`, a `#` comment,
# `${x:-)}`, escaped backticks nested in backticks, and heredoc bodies (a quoted-delimiter body is
# data and is skipped whole; an unquoted one is data too, except for the substitutions in it).
# Every body copy and every scan is charged to the shared work budget, so a pathological nest is
# denied as too costly instead of being scanned (a timed-out hook allows).
_WORD_RE = re.compile(r"\w+")
_CMD_KEYWORDS = ("then", "do", "else", "elif", "if", "while", "until", "time", "!")
_BT_ESCAPE_RE = re.compile(r"\\([`\\$])")
# The delimiter is the whole shell word: a quoted word, or a run of plain characters that must end
# at a blank or a metacharacter (`EOF-1` is one delimiter; `E"O"F` and `$x` are not read at all, so
# the body is scanned as code, never skipped). `<<\EOF` (a backslash-quoted word) is read the same way.
_HD_START_RE = re.compile(
    r"<<-?[ \t]*(?:'([^'\n]+)'|\"([^\"\n]+)\"|(\\?[^\s;&|<>()'\"`$\\]+))(?=[\s;&|<>()]|$)")

class _Unparsed(Exception):
    pass

def _in_arith(s, i):
    # `$((1<<EOF))` and `((x<<EOF))` shift; they open no heredoc. Looks back on the same line, with
    # quoted text masked (`echo "((" ; cat <<X` is no arithmetic), for a `((` no `))` has closed.
    ls = s.rfind("\n", 0, i) + 1
    _scan_cost(i - ls)
    line = _mask_quotes(s[ls:i])
    return line.rfind("((") > line.rfind("))")

def _in_subscript(s, i, loose=False):
    # GH #842/#844, the new views only: a `<<` inside an unclosed `$[` on its line (`$[1<<E]`), inside the
    # subscript of an assignment word (`a[1<<E ]=1`: a name, `[`, no blank up to the `<<`, `]=` after it), or
    # inside the parens of a compound array assignment (`a=(1<<E)`),
    # is a shift, not a heredoc. Any other `[` (`echo x[; cat <<'E'`, `echo a[1<<E]`) leaves it a heredoc.
    # Develop's paths keep _in_arith alone (there an unreadable heredoc denies), so this never turns a deny
    # into an allow.
    ls = s.rfind("\n", 0, i) + 1
    _scan_cost(i - ls)
    line = _mask_quotes(s[ls:i])
    # A compound array assignment (`a=(1<<E)`, `a+=(<<E)`): bash reads no heredoc in its parens.
    ca = max(line.rfind("=("), line.rfind("+=(") + 1)
    if ca > line.rfind(")") and ca > 0 and re.search(r"(?:^|[\s;&|(])[A-Za-z_]\w*\+?$", line[:ca]):
        return True
    ob = line.rfind("[")
    if ob <= line.rfind("]") or ob < 1:
        return False
    if line[ob - 1] == "$":
        k = ob - 1
        while k >= 0 and line[k] == "$":
            k -= 1
        return (ob - 1 - k) % 2 == 1  # `$$[` is the PID then a literal `[`
    if loose:  # the "brk" reading: any unclosed `name[` (`a[ 1<<E]=1`, `a[1<<E]` with no `=`)
        return line[ob - 1].isalnum() or line[ob - 1] == "_"
    if re.search(r"[\s;&|()<>]", line[ob + 1:]) or not re.match(r"<<[^\]\n]*\]\+?=", s[i:]):
        return False
    k = ob - 1
    while k >= 0 and (line[k].isalnum() or line[k] == "_"):
        k -= 1
    return k < ob - 1 and not line[k + 1].isdigit() and (k < 0 or line[k] in " \t;&|(")

def _scan_cost(k):
    global _work
    _work += k
    if _work > _WORK_BUDGET:
        raise _TooCostly

def _line_end(s, pos):
    # The newline that ends the logical line from pos: a backslash-newline continues it. -1 if none.
    while True:
        e = s.find("\n", pos)
        if e < 0:
            return -1
        k = e
        while k > 0 and s[k - 1] == "\\":
            k -= 1
        if (e - k) % 2 == 0:
            return e
        pos = e + 1

def _heredoc_at(s, i, after=None, shift=True):
    # A heredoc operator at s[i]: (trigger, body start, body end, terminator end, quoted delimiter),
    # or None when it opens no body (arithmetic shift, or no newline follows). The trigger is the
    # newline where the body begins. A second heredoc on the same line passes `after`, the first
    # one's terminator end: its body starts on the next line and its trigger is that terminator end.
    # Reading an operator wrongly feeds prose to the quote tracker as code, and one apostrophe in it
    # hides every later substitution, so "scan it as code" is NOT the safe direction. Anything not
    # understood (a delimiter that is not one plain or quoted word, no terminator, or a terminator
    # that bash/sh and a lenient reading place differently, like `X)` inside `$(...)`) raises
    # _Unparsed, and the command is denied.
    m = _HD_START_RE.match(s, i)
    eol = _line_end(s, m.end() if m else i)
    if eol < 0 or shift and _in_arith(s, i):  # GH #844: shift=False reads a `<<` in (( )) as a heredoc too
        return None
    if not m:
        raise _Unparsed
    word = m.group(1) or m.group(2) or m.group(3)
    trigger = eol if after is None else after
    _scan_cost(len(s) - i)
    d = re.escape(word.lstrip("\\"))
    lead = "^\t*" if s[i + 2:i + 3] == "-" else "^"  # no shell accepts a space-indented terminator
    strict = re.compile(lead + d + "$", re.MULTILINE).search(s, trigger + 1)
    # The one known disagreement: bash and sh end a heredoc inside `$(...)` at `X)`; trailing blanks
    # are the other unsure spot. A body line that merely starts with the word (`PY'''`) is not one.
    lenient = re.compile(lead + d + r"(?:[ \t]*\)|[ \t]*$)", re.MULTILINE).search(s, trigger + 1)
    if not strict or not lenient or strict.start() != lenient.start():
        raise _Unparsed
    return (trigger, trigger + 1, strict.start(), strict.end(), m.group(3) is None or word.startswith("\\"))

# GH #512: the scanner below and _quotemask.py each decide what opens a comment and what opens `$'..'`,
# and they drifted: five shapes hid a `git stash` from the scan. These two helpers read the mask's rules
# (see _quotemask.py: its _WORD_BOUNDARY_CHARS, the line-continuation rule of GH #286/#306 and the `$`
# run rule of GH #161) so the two agree again.
_COMMENT_BOUNDARY = " \t;&|("

def _comment_starts(s, i, start, comment_nl=-1, lookback=True, paren_close=False):
    # Does the `#` at s[i] open a comment? Yes at the start of the text or after a blank, ; & | ( or a
    # real newline. A backslash-newline pair is deleted by the shell, so look back past it: one backslash
    # leaves what stood before the pair (`echo x \<nl>#y` is a comment, `x\<nl>#y` is one word); a longer
    # odd run leaves escaped backslashes, which are word characters. comment_nl is the newline that ended a
    # comment, which the text alone cannot say (a comment ends at its newline even when it ends in a
    # backslash). A `)` is not a boundary: it often ends a word (`$(true)#x`) and the scanner does not
    # track which parens are real subshells, so that shape stays open (GH #512). lookback=False is the
    # reading where a `#` after a backslash-newline is a word character (inside `${..}`, `((..))`, `a[..]=`
    # it is); the caller scans both readings rather than guess which context it is in. paren_close=True is
    # the reading where a `)` ends a word boundary (it closes a real subshell: `(true)#x`); in the other
    # reading it is part of a word (`$(true)#x`, `${y:-)#x}`), and the scanner cannot tell which.
    j = i
    while j > start and s[j - 1] == "\n":
        if lookback and j - 1 == comment_nl:  # the other reading must stay develop's
            return True
        k = j - 1
        while k > start and s[k - 1] == "\\":
            k -= 1
        run = j - 1 - k
        if run % 2 == 0:
            return True  # a real newline
        if run > 1 or not lookback:
            return False
        j = k
    if j == start:
        return True
    if s[j - 1] not in _COMMENT_BOUNDARY and not (paren_close and s[j - 1] == ")"):
        return False
    b = 0  # an escaped boundary character (`\;`, `\ `, `\)`) is part of the word, so the `#` is no comment
    while j - 2 - b >= start and s[j - 2 - b] == "\\":
        b += 1
    return b % 2 == 0

def _dollar_run_odd(s, i):
    # Only the LAST `$` of an odd-length run of unescaped `$` can open `$'..'`; `$$` is the PID.
    n, p = 0, i
    while p >= 0 and s[p] == "$":
        b = 0
        while p - 1 - b >= 0 and s[p - 1 - b] == "\\":
            b += 1
        if b % 2:
            break  # this `$` is escaped
        n += 1
        p -= 1
    return n % 2 == 1

_DOLLAR_PAIR_RE = re.compile(r"\$\$'")
_BSNL_HASH_RE = re.compile(r"\\\n#")
_PAREN_HASH_RE = re.compile(r"\)(?:\\\n)*#")

def _substitution_bodies(s, depth=0):
    # GH #512. Every rule that changes what counts as a comment or a `$'..'` can hide a body the old rule
    # found, and each review round found another place. So the scan is a pool: the legacy reading (the
    # rules from before #512, exactly) plus the corrected readings. The pool is a superset of the legacy
    # scan, so nothing the legacy scan found can be lost; the corrected readings add what it missed.
    # Corrected readings: `$$'` is the PID then a plain quote in bash/sh but `$` then `$'..'` in zsh, and a
    # `#` right after a backslash-newline is a comment in command position but a word character inside
    # `${..}`, `((..))` or `a[..]=`, which the scanner does not track; and a `)` right before `#` either
    # closes a subshell (a boundary) or ends part of a word, which it does not track either.
    dollars = [False, True] if _DOLLAR_PAIR_RE.search(s) else [False]
    looks = [True, False] if _BSNL_HASH_RE.search(s) else [True]
    bodies = _scan_bodies(s, depth, False, True, True)
    parens = [False, True] if _PAREN_HASH_RE.search(s) else [False]
    for z in dollars:
        for lb in looks:
            for pc in parens:
                bodies.extend(_scan_bodies(s, depth, z, lb, False, pc))
    return bodies

_hd_collect = None  # GH #842: (text, list) while _prose asks _scan_bodies which heredocs it opens

def _scan_bodies(s, depth=0, zsh_dollar=False, lookback=True, legacy=False, paren_close=False):
    bodies, n, i = [], len(s), 0
    # frame: kind, body start, open quote, paren depth, open `case` count, saw case, at command
    # position, open ${ count
    frames = [["top", 0, None, 0, 0, False, True, 0]]
    pend = []  # heredocs whose bodies start after the current line, in order
    hd_end = hd_depth = -1
    comment_nl = -1  # the newline that ended the last comment
    _scan_cost(n * 4)

    def done(f, end):
        body = s[f[1]:end]
        _scan_cost(len(body))
        if f[0] == "bt" and _BT_ESCAPE_RE.search(body):
            # Inside backticks \` \$ and \\ are escapes the shell reads off before it runs the body
            # (`"\$(git stash)"` runs it); read one level off and rescan. Each level of backticks
            # doubles the backslashes, so this recursion is log-deep.
            body = _BT_ESCAPE_RE.sub(r"\1", body)
            bodies.extend(_substitution_bodies(body))
        if f[5]:  # a case pattern's `)` opens a command; make it a separator (same length, offsets hold)
            body = body.replace(")", ";")
        bodies.append(body)

    while i < n:
        if pend and i == pend[0][0]:
            _, bs, be, te, quoted = pend.pop(0)
            if quoted:
                i = te
                continue
            hd_end, hd_depth = be, len(frames)
        f, c = frames[-1], s[i]
        if i < hd_end and len(frames) == hd_depth and c not in "\\`" \
                and not (c == "$" and s[i + 1:i + 2] in ("(", "{")):
            i += 1  # heredoc text: quotes, parens, # and $' are literal there; only expansions count
            continue
        if f[2] == "'":
            if c == "'":
                f[2] = None
        elif f[2] == "$":  # $'...': a backslash escapes the next character, so \' does not close it
            if c == "\\":
                i += 1
            elif c == "'":
                f[2] = None
        elif c == "\\":
            i += 1
        elif c == "'" and f[2] is None and f[0] != "bt":  # inside "..." an apostrophe is a letter
            f[2] = "'"
        elif c == "$" and s[i + 1:i + 2] == "'" and f[2] is None and f[0] != "bt" \
                and (legacy or zsh_dollar or _dollar_run_odd(s, i)):
            f[2] = "$"; i += 1
        elif c == '"':
            f[2] = None if f[2] == '"' else '"'
        elif c == "#" and f[2] is None and (
                (i == f[1] or s[i - 1] in " \t;&|(" or (s[i - 1] == "\n" and _line_end(s, i - 1) == i - 1))
                if legacy else _comment_starts(s, i, f[1], comment_nl, lookback, paren_close)):
            # a comment (any frame): its quotes, parens and `<<` mean nothing; in backticks the
            # closing backtick still ends it
            j = s.find("\n", i)
            k = s.find("`", i) if f[0] == "bt" else -1
            ends = [x for x in (j, k) if x >= 0]
            i = (min(ends) if ends else n) - 1
            if j >= 0 and ends and j == min(ends):
                comment_nl = j
        elif c == "<" and f[2] is None and s.startswith("<<", i) \
                and s[i + 2:i + 3] != "<" and s[i - 1:i] != "<":
            h = _heredoc_at(s, i, pend[-1][3] if pend else None)
            if h:
                pend.append(h)
                if _hd_collect is not None and _hd_collect[0] is s and not f[7] \
                        and not any(g[0] == "bt" for g in frames) and not _in_subscript(s, i):
                    _hd_collect[1].append((h[1], h[3]))  # GH #842: a heredoc this scan opens (see _prose)
            i += 1
        elif c == "`":
            if f[0] == "bt" and f[2] is None:
                done(f, i); frames.pop()
            # zsh reads a backtick inside quotes inside backticks as a nested open, bash as the
            # close. Both are scanned: the nested frame below is zsh's reading, and the tail added
            # here is bash's (the outer body ends at this backtick, the rest runs one level up).
            else:
                if f[0] == "bt":
                    _scan_cost(n - i)
                    bodies.append(s[i + 1:])
                    if depth < 2:  # the tail may open backticks of its own; two levels, budget-charged
                        bodies.extend(_substitution_bodies(s[i + 1:], depth + 1))
                frames.append(["bt", i + 1, None, 0, 0, False, True, 0])
        elif c == "$" and s[i + 1:i + 2] == "(":
            frames.append(["paren", i + 2, None, 0, 0, False, True, 0]); i += 1
        elif c == "$" and s[i + 1:i + 2] == "{":
            f[7] += 1; i += 1
        elif c == "}" and f[7] and f[2] in (None, '"'):  # also inside "...": `"${x}"` must close
            f[7] -= 1
        elif f[0] == "paren" and f[2] is None:
            # f[6]: at a command position, so only a `case` there opens a case (`echo case` does not)
            if c in " \t":
                pass
            elif c == "(":
                f[3] += 1; f[6] = True
            elif c == ")":
                f[6] = bool(f[4])
                if f[7]:
                    pass  # `${y:-)}`: a literal paren
                elif f[3]:
                    f[3] -= 1
                elif not f[4]:  # a `)` that ends a case pattern is not the end of the body
                    done(f, i); frames.pop()
            elif c.isalpha() and not (s[i - 1].isalnum() or s[i - 1] in "_$"):
                m = _WORD_RE.match(s, i)
                w = m.group() if m else c
                if w == "case" and f[6]:
                    f[4] += 1; f[5] = True
                elif w == "esac" and f[4] and f[6]:  # `echo esac` does not close a case
                    f[4] -= 1
                f[6] = w in _CMD_KEYWORDS
                i += len(w) - 1
            else:
                f[6] = c in ";&|\n{"
        i += 1
    for f in frames[1:]:
        done(f, n)
    return bodies

# A heredoc body is data (`git commit -m "$(cat <<'EOF' ... EOF)"`), so blank it before the check.
# A $(...) nested in it is its own entry in _substitution_bodies and is still checked. The operator
# is looked for on the quote-masked text, so a `<<A` inside quotes cannot blank a real command.
_HD_OP_RE = re.compile(r"(?<!<)<<(?!<)")

def _heredoc_spans(s):
    spans, line_end, last = [], -1, None
    for m in _HD_OP_RE.finditer(_mask_quotes(s)):
        p = m.start()
        _scan_cost(len(spans))
        if any(a <= p < b for a, b, _ in spans):  # inside a body already blanked
            continue
        chained = last is not None and p < line_end  # a second heredoc on the same line as the previous one
        h = _heredoc_at(s, p, last[3] if chained else None)
        if h:
            if not chained:
                line_end = s.find("\n", p)
            last = h
            spans.append((h[1], h[2], h[4]))
    return sorted(spans)

def _blank_heredocs(s):
    out, i = [], 0
    for a, b, _ in _heredoc_spans(s):
        out.append(s[i:a]); out.append(re.sub(r"[^\n]", "Q", s[a:b])); i = b
    return "".join(out) + s[i:]

# GH #844: the main view masks the whole command, heredoc bodies included, so a `'` in a body (`don't`)
# opened a span that ran past the delimiter and hid the commands after it. Two more views blank the bodies,
# each checked as well as the main view, never in place of it, so each can only add a deny:
# - by mask: the operators the mask shows, one at a time, masking again after each blank, so an earlier
#   body is gone before the next operator is looked for (_heredoc_spans finds them all on one mask, which a
#   quote in an earlier body throws off). It masks again only after a body that holds a char that can change
#   the mask's state, and stops after _HD_SEQ_MAX operators (the raw view goes on);
# - raw: every `<<` in the text in order, the mask not asked, so an operator the top-level mask hides
#   (`"$(cat <<'EOF'` with a lone `"` in the body) still blanks its body. One inside quotes or a comment
#   blanks prose, which is why it is a view of its own.
# An operator either cannot read (_Unparsed) is skipped: a `<<` in prose must never deny by itself.
_HD_SEQ_MAX = 24
_HD_STATE_RE = re.compile(r"['\"`\\#$()<]|\b(?:case|esac)\b")

_HD_MODES = ("sub", "dev", "all", "brk")
_CONT_RE = re.compile(r"(?<!\\)((?:\\\\)*)\\\n")  # an odd backslash run, then a newline: its last pair

def _blank_heredocs_seq(s, raw_ops, mode="sub"):
    # mode is how a `<<` that may be a shift is read: "dev" as develop's _in_arith reads it, "sub" also as a
    # shift in a subscript (_in_subscript), "all" always as a heredoc. Each mode is its own view, so a wrong
    # answer in one (`((echo a) )` is no arithmetic, `echo a[<<E]=1` no subscript) is covered by another.
    t, pos, line_end, last, spans = s, 0, -1, None, []
    mt = None if raw_ops else _mask_quotes(t)
    while True:
        if mt is None and not raw_ops:
            if len(spans) >= _HD_SEQ_MAX:
                raw_ops = True  # past the cap the mask view goes on as the raw one
            else:
                _scan_cost(len(t))
                mt = _mask_quotes(t)
        m = _HD_OP_RE.search(t if raw_ops else mt, pos)
        if not m:
            return t, spans
        p = m.start()
        pos = m.end()
        r = p
        while r > 0 and t[r - 1] == "\\":
            r -= 1
        if (p - r) % 2 == 1:
            continue  # `\<<F`: the first `<` is escaped, so no heredoc opens (the raw scan sees `<<` anyway)
        chained = last is not None and p < line_end  # a second heredoc on the line of the one before
        try:
            h = _heredoc_at(t, p, last[3] if chained else None, mode != "all")
        except _Unparsed:
            continue
        if h and mode in ("sub", "brk") and _in_subscript(t, p, mode == "brk"):  # only once a heredoc is found: a long line of shifts stays linear
            continue
        if h:
            if not chained:
                line_end = t.find("\n", p)
            last = h
            # The body and its terminator word become one Q word: offsets hold, and the anchor scans (charged
            # per line start) see one line where the body had many.
            spans.append((h[1], h[3]))
            body = t[h[1]:h[3]]
            q = "Q" * len(body)
            t = t[:h[1]] + q + t[h[3]:]
            if mt is not None and not raw_ops:
                mt = None if _HD_STATE_RE.search(body) else mt[:h[1]] + q + mt[h[3]:]

_hd_view_memo = {}

# PR #872 review 24: a view whose mask matches its base outside the bodies it blanked adds no anchor to
# _violation, but _violation_in_bodies reads the raw view text at each shell word, and there a `)` in a
# blanked body no longer ends an unquoted `$(` word (`eval $(cat <<'E'` / `)` / `E` / `echo true)"; git stash"`).
# Such a view is kept as a _BodyView (text, mask, bodies): the shell bodies its raw text reads that the base
# text reads otherwise. Its mask matches the base's outside the blanked bodies, so its shell words are the
# base's (found once per base, as develop's body check charges it), less any in a blanked body; a body is
# read forward from its word, so only a word before the last blanked char can read differently. Only its
# bodies are checked: no anchor passes, and it seeds no line-join or cut views.
class _BodyView(tuple):
    pass

_shell_matches_memo = {}
# A superset of where _SHELL_RES can match (its shell word follows a blank, a separator, `/` or a backslash): a
# linear look, so a command with no shell word before its last blanked body pays no shell-word scan.
_SHELL_HINT_RE = re.compile(r"(?<!\w)(?:bash|sh|zsh|dash|ksh|eval|rtk)(?=\s)")

def _body_view(t, mt, s, base, end):
    if not _SHELL_HINT_RE.search(base, 0, end + 5):  # a word that starts before end
        return None
    k = (s, base)
    if k not in _shell_matches_memo:
        _charge(base)
        _shell_matches_memo[k] = [m for r in _SHELL_RES for m in r.finditer(base)]
    bodies = []
    for m in _shell_matches_memo[k]:
        if m.start() >= end or mt[m.start():m.end(1) + 1] != base[m.start():m.end(1) + 1]:
            continue
        seen = _bodies_at(s, base, m)
        for b in _bodies_at(t, mt, m):
            if b not in seen and b not in bodies:
                bodies.append(b)
    return _BodyView((t, mt, tuple(bodies))) if bodies else None

def _add_view(views, v):
    # Append v unless an equal view is there (a _BodyView, three items, never equals a full view).
    if v in views:
        return False
    views.append(v)
    return True

def _hd_view(s, base, raw_ops, mode="sub"):
    # (blanked text, its mask) when it shows something base (a mask of s, or of s with fewer bodies blanked)
    # does not: a char that differs outside the blanked bodies (else a _BodyView, if a shell word there reads a
    # body differently). Where nothing differs it can add no anchor
    # (each body starts at a line start and ends at its terminator's line end), and skipping it keeps a big heredoc document under the
    # work budget.
    k = (_dollar_join, s, base, raw_ops, mode)
    if k not in _hd_view_memo:
        v = None
        b, spans = _blank_heredocs_seq(s, raw_ops, mode)
        if spans:
            mb = _mask(b)
            keep, last = [], 0
            for x, y in spans:
                keep.append((last, x)); last = y
            keep.append((last, len(s)))
            if any(mb[x:y] != base[x:y] for x, y in keep):
                v = (b, mb)
            else:
                v = _body_view(b, mb, s, base, spans[-1][1])
        _hd_view_memo[k] = v
    return _hd_view_memo[k]

def _nl_view(s, base):
    # GH #843: s masked with words joined across line continuations, in each joined reading that differs from
    # its plain mask (a list of views). Reading 2 also drops a word match that runs through a backslash-newline
    # that looks like no continuation; that look comes from masking one line alone, which can misread a line
    # that starts inside a quote, so it is a reading of its own, never in place of reading 1.
    global _nl_join
    if "\\\n" not in s or ("'" not in s and '"' not in s):
        return []
    out = []
    for mode in (1, 2):
        _nl_join = mode
        try:
            m = _mask(s)
        finally:
            _nl_join = 0
        if m != _mask(s) and (s, m) not in out:
            out.append((s, m))
    return out

# GH #842: bash ends a backtick substitution at the first unescaped backtick, so a quote span or comment
# the mask opened inside one (`echo 'a`#; git stash`) hides what bash runs after it. The mask reports each
# such backtick (cuts); a view per cut reads the text after it as fresh code, with the text before it
# blanked (it is the base's, which the main scans read) and the backtick itself made a word char, so a
# `#` glued after it stays a word as in bash. Cuts are taken from the text with its heredoc bodies blanked,
# so a backtick in heredoc prose cuts nothing. At most _CUT_MAX views per text.
_CUT_MAX = 8
_prose_memo = {}

def _prose(s, readings=False):
    # s with the bodies of the heredocs bash opens blanked: the source of the cut views (a backtick in
    # heredoc prose is no cut) and a heredoc view of its own. Only the substitution scanner's reading counts:
    # it tracks quotes, comments, $(..) and backtick frames and ${..}, so it opens the body in
    # "$(cat <<'EOF' ..)", where the top-level mask is thrown off, and no body for a `<<` in a comment, a
    # quoted string, `\<<E`, `${v:-<<E}`, a backtick frame or a subscript. Its comment rules have readings it
    # cannot choose between (a `#` after `)` or after a backslash-newline), so a body counts only where every
    # reading opens it (`(true)#<<E` opens none in bash). If it cannot read a heredoc, nothing is blanked.
    # With readings=True: the text per reading instead, each a heredoc view of its own (a comment the
    # scanner reads two ways must not empty the one reading that opens the real heredoc).
    global _hd_collect
    if "<<" not in s:
        return [s] if readings else s
    if s not in _prose_memo:
        common, each = None, []
        try:
            for lb in (True, False):
                for pc in (False, True):
                    spans = []
                    _hd_collect = (s, spans)
                    _scan_bodies(s, 0, False, lb, False, pc)
                    common = set(spans) if common is None else common & set(spans)
                    each.append(set(spans))
        except _Unparsed:
            common = set()
        finally:
            _hd_collect = None

        def blank(spans):
            t = s
            for x, y in sorted(spans):
                t = t[:x] + "Q" * (y - x) + t[y:]
            return t
        _prose_memo[s] = (blank(common), list(dict.fromkeys(blank(e) for e in each)))
    return _prose_memo[s][1] if readings else _prose_memo[s][0]

def _cut_views(texts, base, prose=None):
    # texts: the text(s) to cut, heredoc bodies blanked (see _prose). prose, when given, is the same text with
    # the bodies every scanner reading opens blanked: a cut there is heredoc prose and is skipped (a source
    # whose view blanked a fake `<<` instead must not read prose backticks as cuts).
    # The substitution, from its opening backtick to the cut, becomes word chars, so what stands before it
    # (`env `echo #` git stash`) keeps its place. A cut view is searched for cuts of its own (a second
    # substitution on the line), up to _CUT_MAX views in all.
    views, work, made = [], list(texts), 0
    while work and made < _CUT_MAX:
        t = work.pop(0)
        cuts = []
        _scan_cost(len(t))
        _mask_quotes(t, cuts)
        for o, a in cuts:
            if made >= _CUT_MAX or prose is not None and prose[a:a + 1] != "`":
                continue
            made += 1
            v = t[:o] + "x" * (a - o + 1) + t[a + 1:]
            mv = _mask(v)
            if mv != base:
                views.append((v, mv))
            work.append(v)
    return views

_no_views = False  # PR #872: set for a GH #309 brace-expanded reading over _VIEWS_MAX_CHARS (see below): no extra views
_VIEWS_MAX_CHARS = 16_000  # the default command size cap, fixed (MH_SGG_MAX_CMD_CHARS lifts the cap for stress tests only)

def _extra_views(s, base, based=None):
    # The views of s checked beside (based, base): heredoc bodies blanked (both ways), and each of those and
    # the base text itself read with continuation words joined. based is the text base masks (s itself, or
    # s with some heredoc bodies already blanked); the joined reading is of that text, never of s, so the
    # prose of a body base blanked is never read as code.
    if _no_views:
        return []
    based = s if based is None else based
    views = []
    hd_srcs = []  # (heredoc view text, the text it came from) for the cut views
    if "<<" in s:
        # The raw-operator views and the scanner's per reading below. The mask-found view is left out here:
        # once "$(cat <<'EOF'" throws the top-level mask off it blanks one body and reads the prose after it
        # as code, which cost about 3x develop's work on a script of `cat > f <<'EOF'` blocks and commits,
        # and the scanner views cover the fake operators it was for.
        for raw_ops in (True,):
            for mode in _HD_MODES:
                v = _hd_view(s, base, raw_ops, mode)
                if v and _add_view(views, v) and not isinstance(v, _BodyView):
                    hd_srcs.append((v[0], s))
        for p in _prose(s, True):  # the heredocs the substitution scanner opens, per reading (a fake `<<X`
            if p != s:             # cannot steer these)
                mp = _mask(p)
                # As in _hd_view: a view whose mask differs from the base only inside the bodies it blanked
                # can add no anchor (each body starts at a line start and ends at its terminator's line end),
                # and scanning it whole made any heredoc cost about 1.7x develop's work on the rest.
                if any(a != b for a, b, c, d in zip(mp, base, p, s) if c == d):
                    _add_view(views, (p, mp))
                else:  # see _BodyView
                    bv = _body_view(p, mp, s, base, max(i for i, (c, d) in enumerate(zip(p, s)) if c != d) + 1)
                    if bv:
                        _add_view(views, bv)
    # bash deletes a line continuation before it reads an operator (`<\<nl><'E'`) and, in an unquoted heredoc
    # body, before it compares a line with the delimiter (`x\<nl>E` is no terminator): the heredoc views of
    # the text without its continuations (offsets do not matter here, since each view is scanned whole
    # against its own text). Raw operators only, unless deleting them makes a new operator: the mask-found
    # view of a long script cost about 3x develop's work (see above).
    nc = _CONT_RE.sub(r"\1", s) if "\\\n" in s and "<" in s else s
    if nc != s and "<<" in nc:
        mnc = _mask(nc)
        for raw_ops in ((False, True) if nc.count("<<") > s.count("<<") else (True,)):
            for mode in _HD_MODES:
                v = _hd_view(nc, mnc, raw_ops, mode)
                if v and _add_view(views, v) and not isinstance(v, _BodyView):
                    hd_srcs.append((v[0], nc))
    if "`" in s:
        # Cut sources: the scanner's readings (a heredoc only some open is blanked in one of them) and every
        # heredoc view's text so far (a heredoc only those views find: `cat <\<nl><'E'`, `((echo a) )`).
        # Each source has its own cap, so one cannot use up the views another needs.
        srcs = [(t, None) for t in dict.fromkeys([_prose(s)] + _prose(s, True) if "<<" in s else [based])]
        srcs += [(t, _prose(o)) for t, o in hd_srcs if t not in dict(srcs)]
        if "<<" in s:  # the raw "sub" and "brk" readings: a `<<` they read as a shift blanks nothing, so no filter
            for mode in ("sub", "brk"):
                sub = _blank_heredocs_seq(s, True, mode)[0]
                srcs = [(t, f) for t, f in srcs if t != sub] + [(sub, None)]
        for src, prose in srcs:
            for v in _cut_views([src], base, prose):
                _add_view(views, v)
    for v0 in [(based, base)] + [v for v in views if not isinstance(v, _BodyView)]:
        for v in _nl_view(*v0):
            _add_view(views, v)
    return views

# A quoted-delimiter body is data, never a command. Cutting it out before the substitution scans
# keeps a big document written by `cat > f <<'EOF'` from spending the shared work budget (it would
# otherwise be refused as too costly, a new deny develop never made). Offsets do not matter here:
# the scans return body strings, not positions.
def _drop_quoted_heredocs(s):
    out, i = [], 0
    for a, b, quoted in _heredoc_spans(s):
        if quoted:
            out.append(s[i:a]); i = b
    return "".join(out) + s[i:]

# The bodies of `bash -c '<body>'` / `eval "<body>"` in a text (one level, like _violation_in_bodies).
def _shell_bodies(raw):
    mt = _mask(raw)
    out = []
    for overlap in (False, True, 2):
        _charge(mt)
        for m in _SHELL_RES[overlap].finditer(mt):
            out.extend(_bodies_at(raw, mt, m, for_subs=True))
    return out

# The substitution texts are built once (a scan plus a heredoc blank and a mask per body) and checked
# on every anchor pass, the same per-pass order develop's #281 introduced, so a deny that the plain
# pass finds is found before the cost of the lazy pass.
_sub_texts = None

def _substitution_texts():
    global _sub_texts
    if _sub_texts is None:
        try:
            raw = _drop_quoted_heredocs(cmd)
        except _Unparsed:
            # Only a cost cut. A `"` inside a heredoc message inside `"$(cat <<'EOF' ...)"` throws the
            # top-level quote mask off, so a `<<` in the prose can look like a bad operator here;
            # that must never deny. Scan the whole text instead.
            raw = cmd
        # GH #327: a body string is checked once. The second-parse body of an eval copies its substitution
        # spans as they are, so without this every one of them was scanned twice (a late target behind
        # `eval ` + a million backticks went from 4 s to 6 s, too close to the 8 s timeout).
        subs = list(dict.fromkeys(_substitution_bodies(raw)))
        texts = list(subs)
        for t in [raw] + subs:  # `bash -c 'echo "$(git stash)"'`: the shell body has substitutions too
            for sb in _shell_bodies(t):
                texts.extend(_substitution_bodies(sb))
        blanked = [_blank_heredocs(b) for b in dict.fromkeys(texts)]
        _sub_texts = [(b, _mask(b)) for b in blanked]
        for b, (bb, mb) in zip(dict.fromkeys(texts), list(_sub_texts)):  # GH #843/#844: the extra views too
            for v in _extra_views(b, mb, bb):
                if v:
                    _add_view(_sub_texts, v)
    return _sub_texts

_cmd_views_memo = {}

def _cmd_views():
    k = (_dollar_join, cmd)
    if k not in _cmd_views_memo:
        _cmd_views_memo[k] = _extra_views(cmd, masked)
    return _cmd_views_memo[k]

def _violation_everywhere(overlap):
    hit = _violation(masked, overlap) or _violation_in_bodies(cmd, masked, overlap)
    if hit:
        return hit
    for v in _cmd_views():  # GH #843/#844: the command read the other ways, as well
        hit = _view_violation(v, overlap)
        if hit:
            return hit
    for v in _substitution_texts():
        hit = _view_violation(v, overlap)
        if hit:
            return hit
    return None

def _all_passes():
    return _violation_everywhere(False) or _violation_everywhere(True) or _violation_everywhere(_LAZY)

try:
    if len(cmd) > _MAX_CMD_CHARS:
        raise _TooCostly
    hit = _all_passes()
    for _dollar_join in ("'", ""):  # GH #344: the zsh and dash readings of `$` pieces (see _QWORD_RE)
        if hit or not _dollar_joined:
            break
        _sub_texts = None
        masked = _mask(cmd)
        hit = _all_passes()
    # GH #309: bash, ksh and zsh (not dash) expand braces before anything reads the words, so
    # `git {,stash}`, `{,"doas"} git stash` and `env{,} git stash` hid the anchor or the sub word. One
    # last reading checks the text as the shared _bracex module expands it (same module as the main gate).
    if not hit and _bracex and "{" in cmd:
        try:
            _bx = _bracex.expand_text(cmd, _MAX_VIEW_CHARS)
        except (_bracex.TooBig, RecursionError):
            _brace_too_big = True
            raise _TooCostly
        if _bx != cmd:
            # PR #872: the GH #842-#844 extra views read this expansion only while it is within the default
            # command size cap (_VIEWS_MAX_CHARS), so they cost no more here than on any command. A brace list
            # in quoted JSON (`{"k":1,"v":2}`) expands a real 3.8 KB command to 117 KB, which develop scans
            # just under the work budget; views on top of that went over and denied it, where develop allows.
            # Develop has no views in any reading, so leaving them out reads no less than develop, and a short
            # expansion (`git {stash,}` after a quote in a heredoc body) keeps them.
            _raw_cmd, cmd = cmd, _bx
            _no_views = len(_bx) > _VIEWS_MAX_CHARS
            _dollar_joined = False
            for _dollar_join in ("'\"", "'", ""):  # the same three `$` readings as above (git {stash,} $"show")
                if _dollar_join != "'\"" and not _dollar_joined:
                    break
                _sub_texts = None
                masked = _mask(cmd)
                hit = _all_passes()
                if hit:
                    break
            cmd = _raw_cmd
except _TooCostly:
    _err(f"[mh:gate] BLOCKED: subagent ({agent_type}) command is too long or too dense to check "
         f"safely ({len(cmd)} characters" + (", brace expansion over the size the guard reads" if _brace_too_big else "")
         + "); write it to a file with the Write tool and run the file, or split it into smaller commands.")
    journal(GATE_ID, "Bash", "deny", d.get("session_id"))
    os._exit(2)
except _Unparsed:
    _err(f"[mh:gate] BLOCKED: subagent ({agent_type}) command has a heredoc the guard cannot read "
         f"safely (an odd delimiter, a missing terminator, or a terminator shells disagree on); "
         f"write the text to a file with the Write tool, or use a plain `<<'EOF'` heredoc.")
    journal(GATE_ID, "Bash", "deny", d.get("session_id"))
    os._exit(2)
if hit:
    _err(f"[mh:gate] BLOCKED: subagent ({agent_type}) may not run `git {hit}` "
         f"(command: {clip(cmd)!r}) -- no repo-wide git in a concurrent wave "
         f"(docs/METHODOLOGY.md Rule 13); scope every git command to files you own.")
    journal(GATE_ID, "Bash", "deny", d.get("session_id"))
    os._exit(2)
sys.exit(0)
