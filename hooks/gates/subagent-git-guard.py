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
    def _mask_quotes(s):
        out = []
        pad = {}  # GH #306: out index -> blank pairs to put in front of that piece
        word_start = 0
        i, n = 0, len(s)
        at_word_start = True
        while i < n:
            c = s[i]
            if c == "#" and at_word_start:
                while i < n and s[i] != "\n":
                    out.append(" "); i += 1
                continue
            if c == "'":
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
                if (j - i) % 2 == 0 or j >= n or s[j] != "'":
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
            elif c == '"':
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
                out.append(c); i += 1
                at_word_start = c in set(" \t\n;&|()")
                if at_word_start:
                    word_start = len(out)
        return "".join("  " * pad.get(k, 0) + p for k, p in enumerate(out))

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
_dollar_join = "'\""  # the `$` quote kinds joined in this pass
_dollar_joined = False  # a word with a `$` piece was joined, so the other readings differ

def _join_quoted_words(raw, masked):
    global _dollar_joined
    if len(raw) != len(masked) or ("'" not in raw and '"' not in raw):
        return masked
    out, last = [], 0
    for m in _QWORD_RE.finditer(raw):
        if "'" not in m.group() and '"' not in m.group():
            continue
        a, letters, ok = m.start(), [], True
        for p in _QPIECE_RE.finditer(m.group()):
            k = a + p.start()
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
                ok = (masked[k:k + d] in ("", " ", "$") and masked[k + d] == " " and
                      masked[k + d + 1:k + d + 1 + len(body)] == "Q" * len(body) and masked[k + d + 1 + len(body)] == " ")
                letters.append(body)
            if not ok:
                break
        if ok:
            _dollar_joined = _dollar_joined or "$" in m.group()
            j = "".join(letters)
            out.append(masked[last:a]); out.append(" " * (m.end() - a - len(j)) + j); last = m.end()
    return "".join(out) + masked[last:]

# The whole command is masked again by _shell_bodies; on a 2 MB command each mask costs about 1 s.
_mask_memo = {}

def _mask(s):
    k = (_dollar_join, s)
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
            mb = _mask(body)
            hit = _violation(mb, False) or (overlap and _violation(mb, overlap))
            if hit:
                return hit
    return None

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

def _heredoc_at(s, i, after=None):
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
    if eol < 0 or _in_arith(s, i):
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
    return _sub_texts

def _violation_everywhere(overlap):
    hit = _violation(masked, overlap) or _violation_in_bodies(cmd, masked, overlap)
    if hit:
        return hit
    for body, mb in _substitution_texts():
        hit = _violation(mb, overlap) or _violation_in_bodies(body, mb, overlap)
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
            _raw_cmd, cmd = cmd, _bx
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
