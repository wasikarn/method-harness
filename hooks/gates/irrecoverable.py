#!/usr/bin/env python3
import json, os, re, shlex, sys
import bisect  # its own line: tests/hooks/test-gate-canary.sh injects a NameError after the line above

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
    print("[mh:gate] irrecoverable: _bracex not importable (" + str(_e) + "); a command with a brace and a \",\" or \"..\" goes to brace-view (journaled while shadowed)", file=sys.stderr)

GATE_ID = "gate:bash:irrecoverable"

# GH #771: the gate's own wall-clock limit, well under hooks.json's 8 s timeout (a timed-out PreToolUse
# hook lets the tool call run). On expiry it asks, never allows; os._exit also cuts short a git call in
# flight. MH_IRR_DEADLINE_SECS (test-only) can only shorten it.
DEADLINE_SECS = 4.0
try:
    _dl = float(os.environ.get("MH_IRR_DEADLINE_SECS", ""))
except ValueError:
    _dl = 0.0

def _deadline_hit(signum, frame):
    try:
        if not globals().get("_ASKED"):  # an ask already printed stands; a second JSON object is invalid
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                "permissionDecisionReason": "[mh:gate] irrecoverable: ran out of time (" + format(_DEADLINE, "g")
                + " s) checking this command - confirm with user first, or split it into smaller commands"}}))
        sys.stdout.flush()
        _d = globals().get("d")
        _d = _d if isinstance(_d, dict) else {}
        journal(GATE_ID, _d.get("tool_name"), "ask", _d.get("session_id"), rule="deadline")
    finally:
        os._exit(0)

_DEADLINE = _dl if 0 < _dl < DEADLINE_SECS else DEADLINE_SECS
try:
    import signal
    signal.signal(signal.SIGALRM, _deadline_hit)
    signal.setitimer(signal.ITIMER_REAL, _DEADLINE)
except (ImportError, AttributeError, ValueError, OSError):
    pass  # no SIGALRM on this platform: onFailure block in hooks.json still stops a timeout from allowing

def _disarm():
    # Before every exit: a timer firing during shutdown (default SIGALRM, rc 142) or a deny's unwind (ask)
    # would replace the decision already made.
    try:
        signal.setitimer(signal.ITIMER_REAL, 0)
    except Exception:
        pass  # fallback: no timer was armed on this platform

try:
    d = json.load(sys.stdin)
except Exception:
    d = None

# A malformed payload that reaches this script fails closed (truncated JSON,
# tool_input:null). irrecoverable.sh short-circuits empty stdin and payloads
# with no destructive token before python runs, so those allow by design.
if not isinstance(d, dict) or not isinstance(d.get("tool_input"), dict):
    _disarm()
    print("[mh:gate] BLOCKED: malformed PreToolUse payload — failing closed", file=sys.stderr)
    # d may be None or a non-dict here -- pass literals, never d.get(...).
    journal(GATE_ID, None, "deny", None)
    sys.exit(2)

# GH #769/#770: Monitor carries tool_input.command like Bash (a "ws" Monitor has none); context-mode's
# ctx_execute(_file) runs tool_input.code as shell only for language "shell"; ctx_batch_execute runs each
# commands[].command, judged one per run so one command can't hide the next (an open heredoc); the strictest wins.
# Each run gets the outer payload (agent_id, cwd, tool_name) with only tool_input swapped; having no "commands",
# it takes the plain path below.
_tn = str(d.get("tool_name") or "")
_ti = d["tool_input"]
if _tn.endswith(("__ctx_execute", "__ctx_execute_file")):
    _ti["command"] = _ti.get("code", "") if _ti.get("language") == "shell" else ""
elif _tn.endswith("__ctx_batch_execute") and "commands" in _ti:
    import subprocess, time
    # Mirrors context-mode 1.0.169's coerceCommandsArray (src/server.ts): a non-blank string is JSON-parsed
    # if it gives a list, else lifted to [str]; a string item is its own command.
    _cmds = _ti["commands"]
    if isinstance(_cmds, str) and _cmds.strip():
        try:
            _p = json.loads(_cmds)
        except Exception:
            _p = None
        _cmds = _p if isinstance(_p, list) else [_cmds]
    _ask = ""
    _t0 = time.monotonic()
    # 4 s of the hook's 8 s timeout. MH_GATE_BATCH_BUDGET_S (tests) only shortens it; a value that is not a
    # finite number >= 0 falls back to 4. The first command is always judged, so a budget of 0 checks just that one.
    # A batch padded past the budget turns a later command's deny into an ask, never an allow.
    _budget = 4.0
    _bv = os.environ.get("MH_GATE_BATCH_BUDGET_S")
    if _bv:
        try:
            _b = float(_bv)
        except ValueError:
            _b = -1.0
        if 0 <= _b < float("inf"):  # NaN fails both compares
            _budget = min(_b, 4.0)
            if _b > 4.0:
                print("[mh:gate] irrecoverable: MH_GATE_BATCH_BUDGET_S={!r:.40} is over 4; using 4 s".format(_bv), file=sys.stderr)
        else:
            print("[mh:gate] irrecoverable: MH_GATE_BATCH_BUDGET_S={!r:.40} is not a number >= 0; using 4 s".format(_bv), file=sys.stderr)
    _n = 0
    for _c in (_cmds if isinstance(_cmds, list) else []):
        _c = _c if isinstance(_c, str) else _c.get("command") if isinstance(_c, dict) else None
        if not isinstance(_c, str):
            continue
        _n += 1
        if _n > 1 and time.monotonic() - _t0 > _budget:
            _reason = ("[mh:gate] ctx_batch_execute: the gate's %gs time budget ran out before every command was "
                       "checked; confirm the batch, or split it into smaller batches" % _budget)
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                                     "permissionDecisionReason": _reason}}))
            journal(GATE_ID, _tn, "ask", d.get("session_id"))  # structural, no rule id (repo-gotchas.md)
            sys.exit(0)
        _sub = dict(d, tool_input={"command": _c})
        _r = subprocess.run([sys.executable, "-S", os.path.join(os.path.dirname(os.path.abspath(__file__)), "_run.py"), "irrecoverable"],
                            input=json.dumps(_sub), capture_output=True, text=True)
        sys.stderr.write(_r.stderr)
        if _r.returncode != 0:
            sys.exit(2)  # a deny, or a crash: fail closed
        _ask = _ask or _r.stdout
    sys.stdout.write(_ask)
    sys.exit(0)

# Force-push spec v3 (2026-10-30): the one allowed force push is a WHOLE command, read before any view,
# rewrite or tokenizing, that is a single plain `git [-C path] push [opts] <remote> <src:dst>...` over an
# alphabet with no shell meaning (no quote, $, `, \, ; & | < > ( ) { } [ ] * ? ! # ^ , tab or double blank),
# so the text is git's argv. The path, remote, lease ref, src and dst never start with '-', so an option
# can't fill the remote slot (`push -f --mirror HEAD:feat`: git reads --mirror and a repository HEAD:feat). An explicit src:dst ignores remote.<r>.push, push.default
# and branch merge config, and mirror config refuses it. It skips only the force-push denies (git-push-force,
# the ambiguity push arm, a -c remote.<r>.push "+" pair), and only when no dst or lease ref is protected.
_FP_LEASE_ARG = r"[A-Za-z0-9._/][A-Za-z0-9._/-]*(?::[0-9a-f]{4,40})?"
_FP_STRICT_RE = re.compile(
    r"git(?: -C [A-Za-z0-9._/~][A-Za-z0-9._/~-]*)? push"
    r"(?P<opts>(?: (?:-[fuqvn]+|--force|--force-if-includes|--force-with-lease(?:=" + _FP_LEASE_ARG + r")?"
    r"|--set-upstream|--quiet|--verbose|--dry-run|--atomic|--porcelain|--progress|--no-progress))*)"
    r" [A-Za-z0-9._][A-Za-z0-9._-]*(?P<refs>(?: \+?[A-Za-z0-9._/@][A-Za-z0-9._/@-]*:[A-Za-z0-9._/][A-Za-z0-9._/-]*)+)")
# The operator's force-push list (2026-10-27), plus any release/* branch (_fp_protected). The delete-protect checks
# (_protected_ref: update-ref -d, git branch -D and others) keep the older _DELETE_PROTECTED list: widening them is a separate policy change.
_FP_PROTECTED = ("main", "master", "develop", "production", "staging")

def _fp_protected(ref):
    ref = ref.lower()
    for p in ("refs/heads/", "heads/"):
        if ref.startswith(p):
            ref = ref[len(p):]
            break
    return ref in _FP_PROTECTED or ref.startswith("release/")

def _fp_allowed(raw):
    if not isinstance(raw, str):
        return False
    m = _FP_STRICT_RE.fullmatch(raw.strip(" \t\n"))
    if not m:
        return False
    refs = [w.split("=", 1)[1].split(":", 1)[0] for w in m["opts"].split() if w.startswith("--force-with-lease=")]
    refs += [w.split(":", 1)[1] for w in m["refs"].split()]  # src holds no ':', so this is the dst
    return not any(_fp_protected(r) for r in refs)

_FORCE_PUSH_OK = _fp_allowed(d["tool_input"].get("command"))

SQ = chr(39)
DQ = chr(34)  # GH #697: _dequoted decodes $'..' before the heredoc pass
_ANSI_C_QUOTE_RE = re.compile(r"\$" + SQ + r"((?:[^" + SQ + r"\\]|\\.)*)" + SQ)
# 2026-10-24 sweep: a SQL client reads SQL on stdin too (a heredoc, a here-string, a pipe), where the
# -c/-e scan in the rule loop never looks. The stripped heredoc bodies a client reads are kept here and
# checked with the stdin text further down (_sql_stdin_drop). A SQL comment separates words like a blank.
_SQL_CLIENT_RE = re.compile(r"(?<![\w.-])(?:mysql|psql|sqlite3|mariadb|mongosh|mongo|redis-cli)(?![\w.-])")
# GH #697: a client name or flag split by shell quoting (ps""ql, 'psql', $'-a', E""CHO) is the same word to the
# shell, so the name and flag checks below also read the text as the verb views do (_views): $'..' decoded,
# $".." read as "..", then every quote and backslash dropped. A word that may name the client at run time ($C,
# ${C}, $(..), `..`) is _OPAQUE_ARGV0 (_stage_cmd) and counts as a client that may read JavaScript.
_OPAQUE_ARGV0 = "$"

def _dequoted(text):
    if "$'" in text or '$"' in text:
        text = re.sub(r"\$(?=\")", "", _normalize_ansi_c_quotes(text))
    return re.sub(r"[\"'\\]", "", text)

def _may_name_client(text):
    return bool(_SQL_CLIENT_RE.search(text) or _SQL_CLIENT_RE.search(_dequoted(text))) or "$" in text or "`" in text
# GH #621: a block comment may hold a * (/* a * b */), and MySQL's # comment runs to the end of the line.
_SQL_GAP = r"(?:\s|/\*(?:[^*]|\*(?!/)){0,200}\*/|--[^\n]{0,200}\n|#[^\n]{0,200}\n)+"
# GH #607: the rest of the data-destroying statements a client takes: DROP of any stored object (and
# ALTER ... DROP COLUMN), DELETE FROM and UPDATE ... SET with no WHERE before the statement ends, mongo's
# dropDatabase(), drop(), deleteMany({}) and remove({}), and redis FLUSHALL / FLUSHDB.
_SQL_DROP_OBJECTS = (r"TABLE|DATABASE|SCHEMA|INDEX|VIEW|MATERIALIZED" + _SQL_GAP + r"VIEW|USER|ROLE|FUNCTION|PROCEDURE|"
                     r"TRIGGER|SEQUENCE|TYPE|EXTENSION|OWNED|COLUMN|EVENT|COLLECTION")
_SQL_DROP_RE = re.compile(
    r"DROP" + _SQL_GAP + r"(?:" + _SQL_DROP_OBJECTS + r")\b|TRUNCATE" + _SQL_GAP + r"(TABLE" + _SQL_GAP + r")?\w"
    r"|\bDELETE" + _SQL_GAP + r"FROM" + _SQL_GAP + r"[\w.\"`\[\]]+(?:" + _SQL_GAP + r"(?:AS" + _SQL_GAP + r")?\w+)?"
    r"\s*(?:[;|'\"]|$|\bRETURNING\b)"  # a pipe or a closing quote ends the statement too
    r"|\.dropDatabase\s*\(|\.drop\s*\(\s*\)|\.(?:deleteMany|remove)\s*\(\s*\{\s*\}\s*\)"
    r"|\bFLUSH(?:ALL|DB)\b",
    re.IGNORECASE)
# UPDATE ... SET with no WHERE is read per statement in one linear pass, not in the regex above: a tempered
# "no WHERE up to ;" pattern rescans the rest of the text from every UPDATE (2.4 s on 130 KB, near the 8 s
# hook timeout, which allows).
_SQL_UPDATE_RE = re.compile(r"\bUPDATE" + _SQL_GAP + r"[\w.\"`\[\]]+" + _SQL_GAP + r"SET\b", re.IGNORECASE)
_SQL_WHERE_RE = re.compile(r"\bWHERE\b", re.IGNORECASE)
class _SqlDestroys:
    # Same .search(text) interface as the regex it wraps, so every caller of _SQL_DROP_RE reads both.
    def __init__(self, rx):
        self.rx = rx
    def search(self, text):
        if self.rx.search(text):
            return True
        for stmt in re.split(r"[;|]", text):
            ups = [m.end() for m in _SQL_UPDATE_RE.finditer(stmt)]
            for k, at in enumerate(ups):
                if not _SQL_WHERE_RE.search(stmt, at, ups[k + 1] if k + 1 < len(ups) else len(stmt)):
                    return True
        return False
_SQL_DROP_RE = _SqlDestroys(_SQL_DROP_RE)
# GH #559 review 2: SQL a client reads on stdin is matched with its string literals as one word and its
# comments dropped, so text that only mentions a drop (-- removed the DROP TABLE step, LIKE 'truncate x')
# reads nothing. A backslash ends no literal early here: 'a\'; DROP TABLE t is a drop to PostgreSQL.
# The -c/-e path in the rule loop keeps its raw match.
_SQL_LITERAL_RE = re.compile(r"'[^']*'?|\"[^\"]*\"?|--[^\n]*|/\*(?:[^*]|\*(?!/))*(?:\*/)?")

# GH #559 review 3: the stripping models plain quotes and comments only. Text holding a construct it does not
# model ($$ or $tag$ dollar quoting, a backslash, which escapes a quote in MySQL and E'' strings, MySQL's
# /*! executable comment and # comment, a -- with no blank after it, which MySQL reads as minus minus) is
# matched raw: such a dialect may run what the stripper would read as a literal or a comment. GH #559
# review 4: so is a backtick or a [, a quote to MySQL or sqlite3 but plain text to psql.
_SQL_UNMODELED_RE = re.compile(r"\$(?:[A-Za-z_]\w*)?\$|\\|/\*!|#|--(?!\s)|[`\[]")

# GH #621: matched raw, a literal that only mentions a drop denied (SELECT `id` ... WHERE note='truncate table x').
# The plain '...' literals are still one word there, read in order up to the first quote that is not one:
# a literal holding a backslash (a MySQL escape shifts every later pairing), or the end of any construct
# the quote may have opened inside (a backtick, ], ", $tag$, */ or a newline that ends a # or -- comment).
_SQL_PLAIN_LITERAL_RE = re.compile(r"'([^'\\`\[\]\"$\n]*)'")

def _plain_literals_blanked(sql):
    out, at = [], 0
    while True:
        q = sql.find("'", at)
        if q < 0:
            break
        m = _SQL_PLAIN_LITERAL_RE.match(sql, q)
        if not m or "*/" in m.group(1):
            break
        out.append(sql[at:q] + " s ")
        at = m.end()
    out.append(sql[at:])
    return "".join(out)

# GH #621 review: psql and JavaScript end a -- or // comment at a CR, U+2028 or U+2029 as well, so a body
# holding one blanks nothing; nor does a body a non-SQL client reads (mongo and mongosh read JavaScript,
# where a ' may sit in a regex literal), which keeps develop's matching. A non-SQL client named anywhere on
# the heredoc's line or downstream in the pipeline counts (psql -a | mongosh hands the body on).
_SQL_LINE_ENDS_RE = re.compile("[\r\u2028\u2029]")
_NON_SQL_CLIENT_RE = re.compile(r"(?<![\w.-])(?:mongosh|mongo|redis-cli)(?![\w.-])")

# GH #621 review 4: a client that echoes its input copies the body to stdout or a file, from where any route
# (a function, a variable, a temp file, a pipe past the heredoc) may hand it to a JavaScript client. So the
# plain-literal fallback is withdrawn for the whole command when it names mongo/mongosh/redis-cli anywhere,
# or a SQL client takes an echo flag (psql -a -b -e -E -s -L and their long names or prefixes, mysql or
# mariadb -v and --verbose/--tee, sqlite3 -echo), or the text holds an echo, print, log or tee command
# (psql \set ECHO, \echo, \qecho, \w; mysql tee, \T, print, \p; sqlite3 .echo, .print, .trace, .log).
_SQL_CLIENT_ARGS_RE = re.compile(r"(?<![\w.-])(psql|mysql|mariadb|sqlite3)(?![\w.-])([^|;&\n()]*)")
_SQL_ECHO_CMD_RE = re.compile(r"\bECHO\b|\\(?:q?echo|warn|w|write|T|p|print|tee)\b|(?:^|[\s'\"])\.(?:echo|print|trace|log)\b"
                              r"|^\s*(?:tee|print)\b", re.M)
_SQL_ECHO_FLAGS = {  # client: (echo short letters, short letters that take a value, echo long names)
    "psql": ("abeEsL", "cdfvLoFPRThpU", ("echo-all", "echo-errors", "echo-queries", "echo-hidden", "log-file",
                                          "single-step")),
    "mysql": ("v", "#DehpPSuOT", ("verbose", "tee")),
}
_SQL_ECHO_FLAGS["mariadb"] = _SQL_ECHO_FLAGS["mysql"]

def _sql_client_echoes(argtext, dash_vars=frozenset()):
    client, rest = argtext
    if client == "sqlite3":
        return any(w.strip("'\"").lstrip("-") == "echo" for w in rest.split())
    short, valued, longs = _SQL_ECHO_FLAGS[client]
    for w in rest.split():
        w = w.strip("'\"")
        v = re.fullmatch(r"\$\{?([A-Za-z_]\w*)\}?", w)
        if v and v.group(1) in dash_vars:
            return True  # GH #697: a flag the command puts in a variable (F=-a; psql $F)
        if w.startswith("--"):
            name = w[2:].split("=", 1)[0]
            if name and any(o.startswith(name) for o in longs):
                return True
        elif w.startswith("-") and len(w) > 1:
            for ch in w[1:]:
                if ch in short:
                    return True
                if ch in valued:
                    break
    return False

_SQL_RC_ENV_RE = re.compile(r"\b(?:PSQLRC|MYSQL_HOME|MYSQL_TEST_LOGIN_FILE|SQLITE_HISTORY)\b")

def _sql_blanking_allowed(raw):
    if not isinstance(raw, str):
        return False
    dq = _dequoted(raw)  # GH #697: mon""gosh, -v E""CHO=all and $'-a' are read as the shell reads them
    if any(rx.search(t) for t in (raw, dq) for rx in (_NON_SQL_CLIENT_RE, _SQL_ECHO_CMD_RE, _SQL_RC_ENV_RE)):
        return False
    dash_vars = {m.group(1) for m in re.finditer(r"(?<![\w$])([A-Za-z_]\w*)=-", dq)}
    return not any(_sql_client_echoes(m.groups(), dash_vars) for m in _SQL_CLIENT_ARGS_RE.finditer(dq))

_SQL_BLANKING = [True]  # set from the whole command before the first body is read

def _sql_drops(sql, sql_client=True):
    if _SQL_LINE_ENDS_RE.search(sql):
        pass
    elif not _SQL_UNMODELED_RE.search(sql):
        sql = _SQL_LITERAL_RE.sub(lambda m: " " if m.group()[0] in "-/" else " s ", sql)
    elif "'" in sql and sql_client and _SQL_BLANKING[0]:
        sql = _plain_literals_blanked(sql)
    return bool(_SQL_DROP_RE.search(sql))

# GH #559 review 2: set when _strip_heredocs strips a body a SQL client reads that drops, so each body is
# matched once where it is stripped (rescanning every stored body per bash -c / eval body was quadratic).
_SQL_HEREDOC_DROP = [False]
# GH #668 round 3: the line index in the stripped command right after each data body the top-level strip
# kept as text, checked once the tokenizer exists (see _KEPT_MARK).
_KEPT_BODY_ENDS = []
_INTERP_HEREDOC_BODIES = []  # GH #681: quoted bodies python/node reads as its script, scanned like a -c body
_HEREDOC_UNMATCHED = [False]  # the top-level strip, unsure, never found a delimiter (see _KEPT_MARK)
_INTERP_PIPED_SHELL = [False]  # GH #741: the top-level strip met a python/node heredoc script piped into a shell
_CMD_LINES = []  # GH #801: the lines the top-level heredoc strip reads as command lines (no heredoc body line)
# GH #815: more text a shell runs, read by the interp-pipe-shell check after _CMD_LINES: a body a stdin shell reads
# (bash <<'EOF', cat <<'EOF' | bash; its own data heredocs stripped), and a data body put back as text (its
# delimiter not found, ended early, or unsure). _CMD_EXPANDING: a sure data body that expands, of which only the
# $(..) and backtick bodies run.
_CMD_EXTRA = []
_CMD_EXPANDING = []
_CMD_EXTRA_BUDGET = [1_000_000]  # chars of shell-read bodies stripped again; past it, the rest are not read

def _pieces(text, pipe=False):
    # (start, end) of each piece of text split at an unquoted separator: ; & && || and a newline, or with
    # pipe=True a single | or |&. A redirect's & (2>&1, &>f) separates nothing.
    # GH #559 review 2: a # that starts a word comments out the rest of the line (an apostrophe in it opens
    # no quote), and a newline after a trailing | && || continues the pipeline, as it does in the shell.
    out, start, i, q, n, last, last2 = [], 0, 0, None, len(text), "", ""
    while i < n:
        c, w = text[i], 0
        if q:
            if c == "\\" and q == '"':
                i += 1
            elif c == q:
                q = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "\n" and (last == "|" or last + last2 == "&&"):
            pass
        elif pipe:
            if c == "|" and text[i + 1:i + 2] != "|" and text[i - 1:i] != "|":
                w = 2 if text[i + 1:i + 2] == "&" else 1
        elif text.startswith(("&&", "||"), i):
            w = 2
        elif c in ";\n" or (c == "&" and text[i - 1:i] not in (">", "<", "|") and text[i + 1:i + 2] != ">"):
            w = 1
        if c not in " \t\n":
            last, last2 = c, last
        if w:
            out.append((start, i))
            i += w
            start = i
            continue
        i += 1
    out.append((start, n))
    return out

# GH #559 review: the client is the command a pipe stage runs, not the word anywhere in it: "grep -v psql"
# and a gh title naming psql read no SQL. A stage's argv0 is its first word past shell keywords, VAR=x
# assignments and the wrappers that run the word after them (with their value flags; timeout's duration).
# A literal copy of PREFIX_WRAPPERS / FLAG_VALUE_WRAPPERS plus `builtin`, kept separate because it carries
# sudo's full value-option list. A wrapper missing here hides the client, as it does in the rule loop.
_SQL_CLIENTS = ("mysql", "psql", "sqlite3", "mariadb", "mongosh", "mongo", "redis-cli")  # mongo, redis: GH #607
_SQL_STAGE_WRAPPERS = {
    "env": ("-u", "-C", "-S", "--unset", "--chdir", "--split-string"), "command": (), "nohup": (), "time": (),
    "builtin": (), "setsid": (), "rtk": (), "doas": ("-u", "-C"), "exec": ("-a",),
    "sudo": ("-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R", "--user", "--group", "--host",
             "--prompt", "--close-from", "--chdir", "--role", "--type", "--other-user", "--command-timeout"),
    "nice": ("-n", "--adjustment"), "ionice": ("-c", "-n", "--class", "--classdata"),
    "stdbuf": ("-i", "-o", "-e", "--input", "--output", "--error"),
    "timeout": ("-s", "-k", "--signal", "--kill-after"), "gtimeout": ("-s", "-k", "--signal", "--kill-after"),
}
_SQL_STAGE_KEYWORDS = ("!", "{", "if", "elif", "then", "else", "do", "while", "until", "coproc")
_ASSIGNMENT_RE = re.compile(r"[A-Za-z_]\w*\+?=")

def _words(text):
    # The words of text split at unquoted blanks, quotes removed, one at a time (a caller that needs only the
    # first few stops early). An unclosed quote runs to the end of text.
    w, q, has, i, n = [], None, False, 0, len(text)
    while i < n:
        c = text[i]
        if q:
            if c == q:
                q = None
            elif c == "\\" and q == '"' and i + 1 < n:
                i += 1
                if text[i] != "\n":  # a backslash-newline is a line continuation, gone from the word
                    w.append(text[i])
            else:
                w.append(c)
        elif c in " \t\n":
            if has:
                yield "".join(w)
                w, has = [], False
        elif c in "'\"":
            q, has = c, True
        elif c == "#" and not has:  # a comment, to the end of the line
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "\\" and text[i + 1:i + 2] == "\n":
            i += 2
            continue
        else:
            if c == "\\" and i + 1 < n:
                i += 1
                c = text[i]
            w.append(c)
            has = True
        i += 1
    if has:
        yield "".join(w)

# GH #559 review 2: `docker exec <flags> <container> <cmd>` (and podman's) runs <cmd>, as the rule loop reads it.
_DOCKER_EXEC_VALUE_FLAGS = ("-e", "-u", "-w", "--env", "--env-file", "--user", "--workdir", "--detach-keys")

def _stage_cmd(stage):
    # (argv0, the word iterator past it) of a pipe stage: its first word past shell keywords, assignments,
    # the wrappers in _SQL_STAGE_WRAPPERS and a docker exec's flags and container; (None, ()) for none.
    words = _words(stage)
    wrap, skip, duration, docker = None, False, False, 0
    for t0 in words:
        t = t0.lstrip("$({`").rstrip(")}`;")
        if skip:
            skip = False
            continue
        if not t or t in _SQL_STAGE_KEYWORDS:
            continue
        if docker == 1:  # only `docker exec` runs a command named after it
            if t != "exec":
                return "docker", words
            docker, wrap = 2, None
            continue
        if wrap and t.startswith("-"):
            # A short cluster takes the next word when its last letter does (sudo -iu postgres psql).
            # .get: an rtk subcommand (rtk proxy -v psql) is a wrap with no value flags of its own.
            v = _DOCKER_EXEC_VALUE_FLAGS if wrap == "docker" else _SQL_STAGE_WRAPPERS.get(wrap, ())
            skip = t in v or (not t.startswith("--") and "=" not in t and "-" + t[-1] in v)
            continue
        if docker == 2:
            if t.startswith("-"):
                wrap = "docker"
                skip = t in _DOCKER_EXEC_VALUE_FLAGS or (not t.startswith("--") and "-" + t[-1] in _DOCKER_EXEC_VALUE_FLAGS)
                continue
            docker, wrap = 3, None  # the container
            continue
        if duration:
            duration = False
            continue
        if _ASSIGNMENT_RE.match(t):
            continue
        b = t.rsplit("/", 1)[-1]
        if b in ("docker", "podman") and not docker:
            docker = 1
            continue
        if b in _SQL_STAGE_WRAPPERS or (wrap == "rtk" and b in ("proxy", "run", "err", "test", "summary")):
            wrap, duration = b, b in ("timeout", "gtimeout")
            continue
        if t0[:1] in ("$", "`") and b not in _SQL_CLIENTS:
            return _OPAQUE_ARGV0, words  # GH #697: $C, ${C}, $(..), `..` may name a client
        return b, words
    return None, ()

def _runs_sql_client(stage):
    return _stage_cmd(stage)[0] in _SQL_CLIENTS + (_OPAQUE_ARGV0,)

def _has_opaque_argv0(text):
    # GH #697: some command of text is run by a name held in a variable or substitution.
    if "$" not in text and "`" not in text:
        return False
    return any(_stage_cmd(text[s + a:s + b])[0] == _OPAQUE_ARGV0
               for s, e in _pieces(text) for a, b in _pieces(text[s:e], pipe=True))

# GH #559 review 3: every heredoc a line opens is read, in order (cat <<A >/dev/null; psql db <<B), not
# only the first. A here-string's <<< opens none.
# GH #668: the delimiter is a whole shell word, ended by a blank or an operator (<<EOF; is EOF), quotes removed.
_HEREDOC_OPEN_RE = re.compile(r"(?<!<)<<(?!<)(-)?[ \t]*((?:[^ \t;&|()<>'\"\\]|\\.|'[^']*'|\"(?:[^\"\\]|\\.)*\")+)")

def _heredoc_delim(word, expanding=False):
    # (delimiter, quoted) the way the shell removes quotes, or None for a word with an expansion in it
    # (unless expanding: bash never expands the word, it only removes quotes, so $X stays $X).
    if not expanding and ("$" in word or "`" in word):
        return None
    return (re.sub(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"|\\(.)",
                   lambda m: m.group(1) if m.group(1) is not None else
                   re.sub(r'\\([\\"])', r"\1", m.group(2)) if m.group(2) is not None else m.group(3), word),
            any(ch in word for ch in "'\"\\"))

# An unquoted body line that expands: an unescaped backtick, $( or ${ with more than a plain name inside.
_BODY_EXPANDS_RE = re.compile(r"(?<!\\)(?:\\\\)*(?:`|\$\(|\$\{(?![A-Za-z_][A-Za-z0-9_]*\}))")

def _odd_trailing_bs(line):
    return (len(line) - len(line.rstrip("\\"))) % 2 == 1
# A heredoc feeding an interpreter is executable code, not inert data: an interpreter word anywhere on the
# line BEFORE the << counts. GH #559 review 4: not only the heredoc's own pipe stage, since a heredoc on a
# compound command feeds every command in it ({ bash; } <<EOF, while read x; do bash; done <<EOF), and \b
# keeps zsh-5.9 and python3.12 interpreters. Matched once per line, at its first interpreter word.
_INTERPRETER_RE = re.compile(r"\b(bash|sh|zsh|dash|ksh|ash|hush|python3?|python2|perl|ruby|node|nodejs|osascript)\b")
_HEREDOC_SCAN_BUDGET = [3_000_000]  # chars a $( re-read of heredoc lines may parse; past it, a client is assumed

# GH #741 review 6: a stage whose text, quotes and backslashes removed, names no shell (every _STDIN_SHELLS word
# holds "sh") or no python/node cannot pass _reads_stdin_shell / _reads_stdin_interp (shlex only drops quotes and
# backslashes), so it is not split: a line of 60000 `|x` stages paid two shlex.split calls per stage.
_UNQUOTE = str.maketrans("", "", "\"'\\")
_PYNODE_NAME_RE = re.compile(r"python|node")

class _HeredocLine:
    # The statements and pipe stages of one line, parsed once however many heredocs it opens, so a line
    # of 20000 openers costs one parse, not one per opener.
    def __init__(self, line):
        self.line, self.ends, self.stmts, self.stages = line, None, None, {}

    def _stage(self, pos):
        if self.stmts is None:
            self.stmts = _pieces(self.line)
            self.ends = [e for _, e in self.stmts]
        k = bisect.bisect_left(self.ends, pos)
        if k not in self.stages:
            s, e = self.stmts[k]
            st = [(s + a, s + b) for a, b in _pieces(self.line[s:e], pipe=True)]
            # client[j]: a stage from j on runs a SQL client (read downstream of the heredoc's stage)
            client = [False] * (len(st) + 1)
            for j in range(len(st) - 1, -1, -1):
                client[j] = client[j + 1] or _runs_sql_client(self.line[st[j][0]:st[j][1]])
            self.stages[k] = (st, [b for _, b in st], client)
        st, st_ends, client = self.stages[k]
        return k, bisect.bisect_left(st_ends, pos), st, client

    def client(self, pos):
        _, j, _, client = self._stage(pos)
        return client[j]

    def piped_shell(self, pos):
        # GH #567: a stage after the heredoc's runs a shell that reads stdin (_reads_stdin_shell).
        k, j, st, _ = self._stage(pos)
        if (k, "sh") not in self.stages:
            shell = [False] * (len(st) + 1)
            for i in range(len(st) - 1, -1, -1):
                seg = self.line[st[i][0]:st[i][1]]
                shell[i] = shell[i + 1] or ("sh" in seg.translate(_UNQUOTE) and _reads_stdin_shell(seg))
            self.stages[(k, "sh")] = shell
        return self.stages[(k, "sh")][j + 1]

    def shell_reads(self, pos):
        # GH #815: the heredoc's own stage is a shell reading stdin (bash <<'EOF'), or one downstream reads it.
        k, j, st, _ = self._stage(pos)
        seg = self.line[st[j][0]:st[j][1]]
        return ("sh" in seg.translate(_UNQUOTE) and _reads_stdin_shell(seg)) or self.piped_shell(pos)

    def stdin_interp(self, pos):
        # GH #681: (the heredoc's own stage, a later stage) runs python/node reading its script on stdin.
        k, j, st, _ = self._stage(pos)
        if (k, "py") not in self.stages:
            py = [bool(_PYNODE_NAME_RE.search(self.line[a:b].translate(_UNQUOTE))) and _reads_stdin_interp(self.line[a:b])
                  for a, b in st]
            # GH #741 review: nxt[i], the first such stage from i on (None past the last), read in O(1) per opener
            nxt = [None] * (len(st) + 1)
            for i in range(len(st) - 1, -1, -1):
                nxt[i] = i if py[i] else nxt[i + 1]
            self.stages[(k, "py")], self.stages[(k, "pynext")] = py, nxt
        return self.stages[(k, "py")][j], self.stages[(k, "pynext")][j + 1] is not None

    def interp_to_shell(self, pos):
        # GH #741: the first stage from the heredoc's on that runs python/node reading its script on stdin
        # pipes into a shell reading stdin (python3 - <<'EOF' | bash, cat <<EOF | node - | sh): that shell
        # runs whatever the script prints, which the gate never sees.
        self.piped_shell(pos)
        self.stdin_interp(pos)
        k, j, _, _ = self._stage(pos)
        p = self.stages[(k, "pynext")][j]
        return p is not None and self.stages[(k, "sh")][p + 1]

def _heredoc_feeds_sql_client(ctx, openers, views, pos):
    # Whether the heredoc opened at ctx.line[pos] is read by a SQL client: its own pipe stage or one
    # downstream runs one (psql <<EOF, cat <<EOF | mysql). The line is read whole and again from the nearest
    # ( or ` before pos: a $( the heredoc sits in is no separator to _pieces, and a quote may hold it
    # (gh --body "$(cat <<EOF").
    if ctx.client(pos):
        return True
    o = openers[bisect.bisect_left(openers, pos) - 1] + 1 if openers and openers[0] < pos else 0
    if not o:
        return False
    if o not in views:
        _HEREDOC_SCAN_BUDGET[0] -= len(ctx.line) - o
        if _HEREDOC_SCAN_BUDGET[0] < 0:
            return True
        views[o] = _HeredocLine(ctx.line[o:])
    return views[o].client(pos - o)

# GH #567: a shell reads its commands on stdin too: a heredoc piped into it (cat <<EOF | bash), a here-string
# (bash <<< 'cmd') or the words an echo/printf pipes into it (echo 'cmd' | sh). Only a shell that reads stdin
# counts: one with no -c and no script operand (`bash -s args` reads stdin, `bash x.sh` does not).
_STDIN_SHELLS = ("bash", "sh", "zsh", "dash", "ksh", "ash", "hush")  # ash, hush: busybox (GH #662)
def _split_words(seg):
    try:
        return shlex.split(seg)
    except ValueError:
        return None

# GH #674 review: an output redirection anywhere in the stage (`| sh 2>/dev/null`, `| 2>&1 sh`, `| sh > log`)
# leaves the shell's stdin the pipe, so it is no script operand. Its target is the next word when the
# operator stands alone. An input redirection (`sh < f`) gives the shell other commands and is left as it was.
_OUT_REDIR_RE = re.compile(r"(?:\d*|&)>>?(?:\||&\d*-?)?(.*)")

def _without_out_redirects(w):
    out, i = [], 0
    while i < len(w):
        m = _OUT_REDIR_RE.fullmatch(w[i])
        if m:
            i += 1 if m.group(1) or w[i].endswith(("&1", "&2", "&-")) else 2
            continue
        out.append(w[i])
        i += 1
    return out

def _reads_stdin_shell(seg):
    w = _split_words(seg.split("<<<", 1)[0].split("<<", 1)[0])
    if not w:
        return False
    w = _without_out_redirects(w)
    if not w:
        return False
    i = _past_run_prefix(w)  # GH #674: every wrapper the rule loop unwraps, with its options
    if i is None or i >= len(w) or w[i].rsplit("/", 1)[-1] not in _STDIN_SHELLS:
        return False
    k = i + 1
    while k < len(w):
        t = w[k]
        k += 1
        if t == "-s" or (t.startswith("-") and not t.startswith("--") and "s" in t[1:] and "c" not in t[1:]):
            return True  # -s: the rest are positional parameters, commands come from stdin
        if not t.startswith(("-", "+")) or (t.startswith("-") and not t.startswith("--") and "c" in t[1:]):
            return False  # a script operand, or -c
        if t in ("--rcfile", "--init-file"):
            k += 1
        elif t[:1] in "-+" and t[1:2] != "-":
            k += t[1:].count("o") + t[1:].count("O")  # GH #674: each o or O (shopt) takes the next word,
            # as _shell_body's "oO" reads them (-o pipefail, +o histexpand, -eo x, -O extglob)
    return True

# GH #681: python/node reads its script on stdin with no script operand or with `-` (python3 - <<'EOF',
# cat <<'EOF' | node -). Only bare no-value flags may come first; -c, -m, -e, a script or an input
# redirection is any other shape and keeps today's reading.
_STDIN_INTERP_RE = re.compile(r"python[23]?(?:\.\d+)?|node(?:js)?")
def _reads_stdin_interp(seg):
    if "<<<" in seg:
        return False
    w = _split_words(_HEREDOC_OPEN_RE.sub(" ", seg))
    w = _without_out_redirects(w) if w else None
    i = _past_run_prefix(w) if w else None
    if i is None or i >= len(w) or not _STDIN_INTERP_RE.fullmatch(w[i].rsplit("/", 1)[-1]):
        return False
    rest = w[i + 1:]
    while rest and re.fullmatch(r"-[BdEIOqsSuv]+", rest[0]):
        rest = rest[1:]
    return (not rest or rest[0] == "-") and not any(t.startswith("<") for t in rest)

_HD_OFF = ("{", "((", "a(", "[", "=(")  # hd frames where << is no redirection: ${ $(( (( $[ name=(

def _quote_mask(c, stack=None, hd=False):
    # One flag per character of c: quoted ('..', $'..' or "..", its quotes included), backslash-escaped
    # or in a `#` comment. A $(..) or `..` inside ".." is unquoted again (`out="$(claude hi)"` runs claude). Linear, made once
    # per scanned text.
    # GH #668 (hd, _strip_heredocs only): stack carries the state from one line to the next, and ${..},
    # $((..)), ((..)), $[..] and name=(..) are masked too. A `case` inside $( pushes "!", which never pops
    # and masks the rest: its pattern ) would close the $( early.
    mask, i, n = bytearray(len(c)), 0, len(c)
    stack = [None] if stack is None else stack
    while i < n:
        ch, q = c[i], stack[-1]
        if q == "!":
            mask[i:] = b"\1" * (n - i)
            break
        if q in _HD_OFF:
            mask[i] = 1
        if q == SQ:
            mask[i] = 1
            if ch == SQ:
                stack.pop()
        elif q == '"':
            mask[i] = 1
            if ch == "\\" and i + 1 < n:
                mask[i + 1] = 1
                i += 1
            elif ch == '"':
                stack.pop()
            elif hd and c.startswith("$((", i):
                stack.append("((")
                i += 2
            elif ch == "$" and c[i + 1:i + 2] == "(" or hd and ch == "$" and c[i + 1:i + 2] == "{":
                stack.append(c[i + 1])
                i += 1
            elif ch == "`":
                stack.append("`")
        elif q == "$'":
            mask[i] = 1
            if ch == "\\" and i + 1 < n:
                mask[i + 1] = 1
                i += 1
            elif ch == SQ:
                stack.pop()
        elif ch == "\\" and i + 1 < n:
            mask[i + 1] = 1
            i += 1
        elif ch == "$" and c[i + 1:i + 2] == SQ:
            mask[i] = mask[i + 1] = 1
            stack.append("$'")
            i += 1
        elif ch in (SQ, '"'):
            mask[i] = 1
            stack.append(ch)
        elif ch == "#" and (i == 0 or c[i - 1] in " \t\n;&|()"):
            j = c.find("\n", i)  # a comment, to the end of its line
            j = n if j < 0 else j
            mask[i:j] = b"\1" * (j - i)
            i = j
            continue
        elif not hd:
            if q == "(" and ch in "()":
                stack.append(ch) if ch == "(" else stack.pop()
            elif q == "`" and ch == "`":
                stack.pop()
        elif c.startswith("((", i) or c.startswith("$((", i):
            stack.append("((")
            i += 1 if ch == "(" else 2
        elif ch == "$" and c[i + 1:i + 2] in ("{", "[", "("):
            stack.append(c[i + 1])
            i += 1
        elif ch in "<>" and c[i + 1:i + 2] == "(":  # <( and >( read their body as $( does
            stack.append("(")
            i += 1
        elif ch == "=" and c[i + 1:i + 2] == "(":
            stack.append("=(")
            i += 1
        elif ch == "`":
            stack.pop() if q == "`" else stack.append("`")
        elif q == "(" and c.startswith("case", i) and (i == 0 or c[i - 1] in " \t;&|(") and c[i + 4:i + 5] in ("", " ", "\t"):
            stack.append("!")
        elif (q, ch) in (("{", "}"), ("[", "]"), ("=(", ")"), ("a(", ")"), ("(", ")")):
            stack.pop()
        elif q == "((" and ch == ")" and c[i + 1:i + 2] == ")":
            stack.pop()
            i += 1
        elif ch == "(" and q in ("((", "a("):
            stack.append("a(")  # a ( inside arithmetic: its ) closes it, not the (( frame
        elif ch == "(" and q == "(":
            stack.append("(")
        i += 1
    return mask

def _in_subscript(line, mask, starts):
    # Whether an opener at one of starts follows an unmasked [ with no unmasked ] after it. One pass.
    br = False
    for k in range(max(starts) + 1):
        if k in starts and br:
            return True
        if not mask[k] and line[k] in "[]":
            br = line[k] == "["
    return False

def _strip_heredocs(cmd, ends=None, shell_code=False):
    # Heredoc bodies are literal data (a quoted commit message mentioning
    # "rm -rf" must not deny) UNLESS the heredoc is stdin for an interpreter
    # (bash <<EOF / python3 <<EOF), where the body IS code and stays scannable.
    # A body a SQL client reads (psql <<EOF, cat <<EOF | mysql) is checked for a
    # drop whatever the interpreter decision (GH #559 review 3), and one that
    # drops sets _SQL_HEREDOC_DROP for the SQL check.
    # GH #668: a << counts only where the shell reads it as a redirection, so the quote state is carried
    # from line to line (bodies skipped). Once a shape the scan does not model shows up (sure turns False)
    # nothing more is stripped: an opener line ending inside a quote, ${ or $((, or in a backslash; a
    # delimiter with $ or a backtick; an unquoted body that expands $(, `, ${..} or joins lines; inside
    # $( or a backtick (or once unsure), a body line that starts with the delimiter but is not it. Openers
    # are then read as before, for the SQL check only. An interpreter-fed body is skipped like any other
    # (its text is the child's, not this shell's) but kept whole as code, its own heredocs unstripped.
    # GH #668 round 3: ends (the top-level call's _KEPT_BODY_ENDS) gets the index in the output right after
    # each data body kept as text (unsure, or ended early), where the tokenizer must stand outside any
    # quote; bash reads the body as data, so a quote in it must not pair with one past the delimiter. The
    # unmatched-delimiter put-back runs to the end, and a code body is GH #681, so neither is recorded.
    # GH #668 round 4: unsure too, checked on every line while sure: a \ in the delimiter inside a backtick
    # (bash unescapes \\ there first), a ${ $(( (( $[ name=( or case frame still open at the line end, a
    # stack deeper than 64 (keeps `framed` linear), an opener after an unclosed [ (a[1<<2]=3 shifts). A
    # delimiter with $ or a backtick is still searched for with its quotes removed (bash never expands
    # it), and an unsure body whose delimiter is never found denies (_HEREDOC_UNMATCHED): bash may end it
    # elsewhere. Sure and not found keeps the put-back.
    # GH #815 (shell_code): a body counts as code only when a shell reads it (shell_reads), for the re-strip of a
    # shell-read body: `cat > y.sh <<'IN'` in it is data, though y.sh names sh.
    lines = cmd.split("\n")
    out, i, stack, sure = [], 0, [None], True
    while i < len(lines):
        line = lines[i]
        out.append(line)
        if ends is not None:
            _CMD_LINES.append(line)
        i += 1
        ms = list(_HEREDOC_OPEN_RE.finditer(line))
        if sure:
            mask = _quote_mask(line, stack, hd=True)
            real = [m for m in ms if not mask[m.start()]]
            # Unsure too: a masked opener on a SQL client's line (the SQL check reads every opener), and a
            # $( or backtick closing after the opener on its own line (zsh reads that heredoc as empty).
            sure = stack[-1] != "!" and not (len(real) < len(ms) and _SQL_CLIENT_RE.search(line)) and not (real and (
                stack[-1] not in (None, "(", "`") or _odd_trailing_bs(line)
                or any(_heredoc_delim(m.group(2)) is None for m in real)
                or any(not mask[k] and line[k] in ")`" for k in range(real[-1].end(), len(line)))))
            # Checked on every line while sure: a \ in the delimiter inside a backtick (unescaped first), a
            # frame where << is no redirection still open at the line end, a stack past 64 (bounds `framed`),
            # an opener inside an array subscript (bash: a[1<<2]=3 is a shift).
            if sure and (len(stack) > 64 or any(f in _HD_OFF or f == "!" for f in stack[1:])
                         or ("`" in stack and any("\\" in m.group(2) for m in real))
                         or real and _in_subscript(line, mask, {m.start() for m in real})):
                sure = False
            if sure:
                ms = real
        framed = "(" in stack or "`" in stack  # the heredoc sits in $( or a backtick (read only while sure)
        if not ms:
            continue
        ctx, views, has_client, line_sql = _HeredocLine(line), {}, _may_name_client(line), None
        openers = sorted(k for k, ch in enumerate(line) if ch in "(`") if has_client else []
        interp = _INTERPRETER_RE.search(line, 0, ms[-1].start())
        # once per line, not per opener (GH #741 review 5: quadratic); quotes and backslashes removed, as the shell
        # does, so pyth\on3 names python (GH #801)
        unq = line.translate(_UNQUOTE)
        pyline = "python" in unq or "node" in unq
        shline = pyline and "sh" in unq  # no shell word anywhere: no stage reads stdin as one
        for n_m, m in enumerate(ms):
            # GH #567: or a shell reading stdin downstream of it in its pipeline (cat <<EOF | bash), read
            # from the line's stages parsed once.
            code = ctx.shell_reads(m.start()) if shell_code else (
                bool(interp) and interp.start() < m.start() or ctx.piped_shell(m.start()))
            feeds = has_client and _heredoc_feeds_sql_client(ctx, openers, views, m.start())
            strip_tabs, (delim, quoted) = bool(m.group(1)), _heredoc_delim(m.group(2)) or (
                _heredoc_delim(m.group(2), True)[0], True)
            # GH #681: a quoted body python/node reads as its script (its own stage, or a later one: cat <<'EOF' |
            # python3 -) is scanned like a -c body; read by its own stage it is also stripped as data, so its
            # quotes never pair with text past the delimiter. A shell downstream (| bash) keeps today's reading.
            py_own, py_down = ctx.stdin_interp(m.start()) if (
                ends is not None and quoted and pyline) else (False, False)
            py_data = py_own and sure and not framed and not ctx.piped_shell(m.start())
            if ends is not None and not _INTERP_PIPED_SHELL[0] and shline and ctx.interp_to_shell(m.start()):
                _INTERP_PIPED_SHELL[0] = True
            sql_code, code = code, code and not py_data
            body_start, found, expands, early = i, False, False, False
            while i < len(lines):
                body_line = lines[i].lstrip("\t") if strip_tabs else lines[i]
                i += 1
                if body_line == delim:
                    found = True
                    break
                if body_line.startswith(delim) and (framed or not sure):
                    early = True  # bash inside $( ends the body at EOF) too
                    break
                expands = expands or not quoted and (_odd_trailing_bs(body_line)
                                                     or bool(_BODY_EXPANDS_RE.search(body_line)))
            body = "\n".join(lines[body_start:i])
            if py_own or py_down:
                _INTERP_HEREDOC_BODIES.append(body)
            if sql_code and not _SQL_HEREDOC_DROP[0] and _SQL_CLIENT_RE.search(body) and _sql_drops(body):
                _SQL_HEREDOC_DROP[0] = True  # its own heredocs are not read, so a client in it reads its drop
            if ends is not None and not code and (early or not found or not sure):
                _CMD_EXTRA.append("\n".join(lines[body_start:i - 1 if early else i]))
            if early:
                # Unsure from here: the body is kept and the EOF) line is read again as a command line.
                out.extend(lines[body_start:i - 1])
                if ends is not None and not code:
                    ends.append(len(out))
                i, sure = i - 1, False
                break
            if not found:
                # Unmatched closing delimiter: put the scanned lines BACK rather
                # than silently eat a real write statement that followed. Unsure, bash may end the body
                # where the gate does not, so the top-level call denies (_HEREDOC_UNMATCHED).
                out.extend(lines[body_start:i])
                if ends is not None and not sure:
                    _HEREDOC_UNMATCHED[0] = True
                break
            if ends is not None and found and code and ctx.shell_reads(m.start()) and (
                    _CMD_EXTRA_BUDGET[0] >= i - body_start):
                inner = "\n".join(lines[body_start:i - 1])
                _CMD_EXTRA_BUDGET[0] -= len(inner)
                drop = _SQL_HEREDOC_DROP[0]
                _CMD_EXTRA.append(_strip_heredocs(inner, shell_code=True))
                _SQL_HEREDOC_DROP[0] = drop
            elif ends is not None and found and not code and sure and expands:
                _CMD_EXPANDING.append("\n".join(lines[body_start:i - 1]))
            sure = sure and not expands
            if code or not sure:
                out.extend(lines[body_start:i])
                if ends is not None and not code:
                    ends.append(len(out))
            if feeds and not _SQL_HEREDOC_DROP[0]:
                if line_sql is None:  # GH #697 review: read once per line, not once per heredoc on it
                    line_sql = not _NON_SQL_CLIENT_RE.search(_dequoted(line)) and not _has_opaque_argv0(line)
                if _sql_drops("\n".join(lines[body_start:i - 1]), line_sql):
                    _SQL_HEREDOC_DROP[0] = True
    return "\n".join(out)

def _normalize_ansi_c_quotes(cmd, live_only=False):
    # shlex does not understand ANSI-C quoting ($SQ...SQ): a spliced argv0 like
    # $SQ\x74SQ never reassembles into the decoded byte. Dispatch below compares
    # argv0 by EXACT string, so the escape must actually be RESOLVED (a
    # boundary-only re-quote still yields the literal token "gi\x74").
    # Bounded escape set: \xHH, \nnn octal, \uHHHH, \UHHHHHHHH, \cX (control-X), \n \t \r \a \b \e \E \f \v
    # \\ \SQ \DQ (GH #664: \u, \U and \c spelled a verb bash decodes); anything else stays a literal pair.
    # A decoded SQ byte (\SQ, \047, \x27) cannot sit inside the SQ...SQ wrapper
    # returned here, so a second pass splices it into the close-escape-reopen
    # idiom -- otherwise the unbalanced quote desyncs _newlines_to_seps.
    # Decoded newlines stay INSIDE the wrapper so _newlines_to_seps (which runs
    # after this) does not read them as statement separators.
    OCTAL = "01234567"
    HEXDIGITS = "0123456789abcdefABCDEF"
    SIMPLE = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
              "v": "\v", "\\": "\\", SQ: SQ, DQ: DQ}
    def _decode_ansi_c(m):
        body = m.group(1)
        decoded = []
        i, n = 0, len(body)
        while i < n:
            c = body[i]
            if c == "\\" and i + 1 < n:
                nxt = body[i + 1]
                if nxt in SIMPLE:
                    decoded.append(SIMPLE[nxt])
                    i += 2
                elif nxt == "x" and body[i + 2:i + 3] == "{":  # \x{HH...}: any hex digits, the byte is & 0xFF
                    j, digits = i + 3, ""
                    while j < n and body[j] in HEXDIGITS:
                        digits += body[j]
                        j += 1
                    decoded.append(chr(int(digits, 16) & 0xFF) if digits else "\x00")  # bash: \x{} is a NUL
                    i = j + 1 if body[j:j + 1] == "}" else j
                elif nxt == "x":
                    j, digits = i + 2, ""
                    while j < n and len(digits) < 2 and body[j] in HEXDIGITS:
                        digits += body[j]
                        j += 1
                    if digits:
                        decoded.append(chr(int(digits, 16)))
                        i = j
                    else:
                        decoded.append(body[i:i + 2])
                        i += 2
                elif nxt in "uU":
                    j, digits = i + 2, ""
                    while j < n and len(digits) < (4 if nxt == "u" else 8) and body[j] in HEXDIGITS:
                        digits += body[j]
                        j += 1
                    cp = int(digits, 16) if digits else -1
                    if 0 <= cp <= 0x10FFFF:
                        decoded.append(chr(cp))
                        i = j
                    elif digits:  # bash 5.2: from 0x80000000 nothing; past U+10FFFF, bytes no verb is spelled with
                        decoded.append("" if cp >= 0x80000000 else body[i:j])
                        i = j
                    else:
                        decoded.append(body[i:i + 2])
                        i += 2
                elif nxt == "c" and i + 2 < n:  # \cX: X & 0x1f as bash computes it (\cJ and \c* are a newline)
                    x = body[i + 2]
                    if x == "?":
                        decoded.append("\x7f")
                    elif ord(x) < 128:
                        decoded.append(chr(ord(x) & 0x1f))
                    else:  # bash takes the first byte of a multibyte character; the rest stay
                        b = x.encode("utf-8", "surrogatepass")
                        decoded.append(chr(b[0] & 0x1f) + b[1:].decode("latin-1"))
                    i += 4 if x == "\\" and body[i + 3:i + 4] == "\\" else 3
                elif nxt in OCTAL:
                    j, digits = i + 1, ""
                    while j < n and len(digits) < 3 and body[j] in OCTAL:
                        digits += body[j]
                        j += 1
                    decoded.append(chr(int(digits, 8) & 0xFF))
                    i = j
                else:
                    decoded.append(body[i:i + 2])
                    i += 2
            else:
                decoded.append(c)
                i += 1
        spliced = []
        for ch in "".join(decoded).split("\x00", 1)[0]:  # a NUL ends the value, as in bash
            if ch == SQ:
                spliced.append(SQ + "\\" + SQ + SQ)
            else:
                spliced.append(ch)
        return SQ + "".join(spliced) + SQ
    # GH #664 review 3: a here-string or an echo word holds text another shell reads later, and in its "..."
    # a $'...' is literal (decoding a \x22 there early cut the text short). So a $'...' that opens outside
    # quotes, or in a $(...) / `...` inside "...", is decoded, matched at each such start so a literal one
    # cannot swallow a live one. Review 4: the command line's own reading (live_only false) also decodes the
    # rest, as develop did, so a start the scanner misses (a case ) in "$(...)") or one a nested shell reads
    # (sh -c "eval \$'...'") is still read. Those sit in "...", so a decoded " \ $ or backtick is escaped
    # there: it must not reshape the quoting around it (review 4), nor stop the decode (review 5).
    def _rest(m):
        dec = _decode_ansi_c(m)
        return SQ + re.sub(r'(["\\$`])', r"\\\1", dec[1:-1]) + SQ
    out, last = [], 0
    for i in _ansi_c_live_starts(cmd):
        m = _ANSI_C_QUOTE_RE.match(cmd, i) if i >= last else None
        if m:
            gap = cmd[last:i]
            out += [gap if live_only else _ANSI_C_QUOTE_RE.sub(_rest, gap), _decode_ansi_c(m)]
            last = m.end()
    gap = cmd[last:]
    out.append(gap if live_only else _ANSI_C_QUOTE_RE.sub(_rest, gap))
    return "".join(out)

def _ansi_c_live_starts(t):
    # The offsets of each $' that opens an ANSI-C quote the shell decodes: outside quotes, or in a $(..) or
    # `..` nested in "...". Quote state only: a here-string or echo word holds no comment.
    starts, stack, i, n = [], [None], 0, len(t)
    while i < n:
        c, q = t[i], stack[-1]
        if q == SQ:
            if c == SQ:
                stack.pop()
        elif q in ('"', "$'"):
            if c == "\\":
                i += 1
            elif c == (SQ if q == "$'" else '"'):
                stack.pop()
            elif q == '"' and c == "$" and t[i + 1:i + 2] == "(":
                stack.append("(")
                i += 1
            elif q == '"' and c == "`":
                stack.append("`")
        elif c == "\\":
            i += 1
        elif c == "$" and t[i + 1:i + 2] == SQ:
            starts.append(i)
            stack.append("$'")
            i += 1
        elif c in (SQ, '"'):
            stack.append(c)
        elif q == "(" and c in "()":
            stack.append(c) if c == "(" else stack.pop()
        elif q == "`" and c == "`":
            stack.pop()
        i += 1
    return starts

# GH #606, #611 review finding 1: rm -i asks per file, and the Bash tool's stdin gives EOF, which rm reads
# as "no". The command can answer for it instead: a pipe (yes | rm -ri), any < redirect (<, <<, <<<, <&, <>,
# a heredoc, a <(...)), fd 0 duplicated from another (0>&3), a coproc, or a tool that types into a terminal.
# The windows the rm rule reads have lost all of these (pipes split windows, redirects and heredoc bodies are
# deleted before tokenizing), and a group, a loop or a shell body hands its stdin on ({ rm -ri b; } <<< y,
# yes | bash -c 'rm -ri b'), so the raw command is read whole, quotes and all, with the escaped spellings of
# < and | an eval or $'...' could decode. Over-reading costs only the -i exception of a recursive rm. xargs
# is not here: rule xargs-rm denies `xargs rm` whatever its flags (GNU xargs gives rm /dev/null anyway,
# unless -a or -o).
# A terminal driver counts only as a command word (#636 review: `rm -ri build/script` names no driver): at a
# line, statement, group, substitution or quote start, past assignments, wrapper words and a path.
_RM_STDIN_FED_RE = re.compile(
    r"[|<]|(?<!\d)0>&|\\(?:x(?:3c|7c)|0?74|174|u0{0,2}(?:3c|7c)|U0{0,6}(?:3c|7c))"
    r"|(?:^|[;&(){}\n`'\"])\s*(?:(?:[A-Za-z_]\w*=[^\s;&|()`'\"]*|sudo|env|exec|command|builtin|nohup|nice|time|setsid|stdbuf"
    r"|timeout|then|do|else|elif|if|while|until|!)\s+)*(?:[^\s;&|()`'\"]*/)?"
    r"(?:coproc|expect|unbuffer|script|tmux|screen|socat|zpty)(?=[\s;&|)`'\"]|$)", re.IGNORECASE)
_RM_STDIN_FED = []
# #636 review: an interpreter one-liner's process API (subprocess.run(..., input=...), execSync(..., {input}))
# can write rm's stdin itself, so an rm reached through one (_interp_commands) never keeps the -i exception.
# Set before the body's windows are checked, which always follow the window that holds the interpreter.
_RM_VIA_INTERP = [False]

def _rm_stdin_fed():
    if _RM_VIA_INTERP[0]:
        return True
    if not _RM_STDIN_FED:
        raw = d["tool_input"].get("command", "")
        _RM_STDIN_FED.append(not isinstance(raw, str) or bool(_RM_STDIN_FED_RE.search(raw)))
    return _RM_STDIN_FED[0]

# GNU rm's --interactive=WHEN, read as argmatch reads it: an exact word, else a prefix that names one value
# (n, no, non all mean never). An empty, unknown or ambiguous WHEN makes rm exit with an error.
_RM_WHEN = {"never": "never", "no": "never", "none": "never", "once": "once", "always": "always", "yes": "always"}

def _rm_when(v):
    if v in _RM_WHEN:
        return _RM_WHEN[v]
    hits = {m for k, m in _RM_WHEN.items() if v and k.startswith(v)}
    return hits.pop() if len(hits) == 1 else "error"

def _rm_prompts_each(rest):
    # GH #606, #611 review findings 2 and 3: whether rm asks before every file. The last of -f/--force
    # (never), -i/--interactive[=always] (each file), -I/--interactive=once (once, then deletes the tree)
    # wins, and "--" ends the options (a -i after it is a filename). #636 review, operator decision: the
    # options that can grant the prompt end at the first operand, as BSD/macOS rm and GNU rm under
    # POSIXLY_CORRECT read them (there `rm -r build -i` deletes build). GNU rm permutes, so a later -f, -I or
    # --interactive=never|once still voids it; a later -i never grants it. A word that is a substitution or
    # a variable before "--" may expand to -f or to "--", so it voids the prompt.
    mode, operand = None, False
    for t in rest:
        if PH in t or "$" in t or "`" in t:
            return False
        if t == "--":
            break
        if t.startswith("--"):
            name, eq, val = t.partition("=")
            if _is_flag(name, "--force"):
                new = "never"
            elif _is_flag(name, "--interactive"):
                new = _rm_when(val) if eq else "always"
            else:
                continue
            if not operand:
                mode = new
            elif new != "always":
                return False
        elif t.startswith("-") and len(t) > 1:
            for ch in t[1:]:
                new = {"f": "never", "i": "always", "I": "once"}.get(ch)
                if new is None:
                    continue
                if not operand:
                    mode = new
                elif new != "always":
                    return False
        else:
            operand = True
    return mode == "always"

# shlex cost is superlinear in the longest SINGLE token (700k chars blows a 2s
# timeout), so an oversized command denies on length ALONE before shlex runs.
_CMD_LEN_CAP = 150_000

def _mid_merge():
    # `git add -A|--all|.` is allowed only mid-merge (staging a manual conflict
    # resolution needs it). Checked in the payload cwd, not this process cwd.
    import subprocess
    cwd = d.get("cwd") or os.getcwd()
    try:
        r = subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"],
                           cwd=cwd, capture_output=True, timeout=3)
        return r.returncode == 0
    except Exception as e:
        # M7 (harness gap-audit, 2026-09-20): a deny caused by this check itself
        # failing (bad cwd, git missing, timeout) looked identical to a genuine
        # "not mid-merge" deny -- no way to tell them apart from the deny message
        # alone. Diagnostic only; the safe-direction return (deny `git add -A`)
        # is unchanged.
        print(f"[mh:gate] irrecoverable: mid-merge check itself failed (cwd={cwd!r}): {e}",
              file=sys.stderr)
        return False

# --- Nested-spawn deny: a subagent (agent_id present) may not spawn a nested
# `claude -p|--print|--agent|--bg|--worktree` session -- it would run as a fresh
# main session with no agent_id. Anchored on a command-start position so prose
# mentions do not trip it; the flag scan is quote-aware so a separator inside a
# quoted prompt does not end it early. re.MULTILINE: a line inside an
# interpreter-fed heredoc body is its own statement.
# GH #152: `claude\b` alone matched mid-token (a path like /tmp/claude-501/...
# contains a word-bounded "claude", since "-" is a non-word char), and the
# forward flag scan did not stop at a newline, so a later unrelated line's
# flag (e.g. `mkdir -p`) got attributed to that false match. Fixed by
# requiring "claude" to end the token -- next char must not be an
# identifier/path-continuation char (word char, "-", ".", "/") -- and by
# treating an unquoted newline as a scan-stopping separator, same as &/;/|.
# A code-review round on the first attempt caught two dangerous-direction
# regressions before ship, both since covered by tests below: (1) an
# allowlist-shaped exclusion (only \s;&|) rejected legitimate shell
# metacharacters too, e.g. missing `claude>out.log -p x`; a denylist of
# continuation chars is the correct shape. (2) a bare newline-stops-scan rule
# also stopped at a backslash-continued newline (`claude \` + real newline +
# `-p`), which is still ONE shell statement -- the scan now treats a
# `\`-then-newline pair as non-breaking, matching how a real shell (and this
# file's own _newlines_to_seps, used elsewhere) treats line continuations.
# ponytail: only single-backslash continuation is tracked, not escape parity
# (`\\` + newline, an even count, is NOT a continuation in real bash but is
# treated as one here) -- habit-guard, not adversarial sandbox, same posture
# as this file's other documented one-level-only unwraps.
# ponytail: `cat <<EOF | bash` bodies are stripped as inert and not scanned,
# add heredoc-body scanning if a nested-spawn bypass via heredoc is ever demonstrated.
#
# 2026-09-20 audit: a prefix wrapper (env/command/sudo/nice/nohup/time, singly
# or chained -- "env sudo claude -p x") sat between the anchor and "claude"
# with nothing to match it, so the anchor never fired and the deny below
# never ran -- live-confirmed. A bare `\claude` (backslash suppresses alias
# lookup in real bash; the command itself is unaffected) had the same gap.
#
# Fix: an allowance matched against this file's own PREFIX_WRAPPERS word list
# (below), not a generic "any token" skip -- a generic skip was tried first
# and reverted: it made this anchor match `claude` wherever it next appeared,
# including deep inside an unrelated command's quoted argument (broke the
# existing `git commit -m "mention claude -p in docs"` -> ALLOW regression
# test in tests/hooks/test-gates-irrecoverable-2.sh, since this anchor runs on the raw
# command text, not the quote-masked string subagent-git-guard.py's sibling
# anchor uses). Matching only real wrapper WORDS keeps that same precision:
# "git", "commit", "-m", or a quoted-string token never satisfy the
# alternation, so an anchor attempt from string-start still requires
# "claude" immediately, exactly as before this fix.
#
# 2026-09-20 fix-round 2 (compliance-audit vs the plan above): bounding both
# axes at 3 was itself a deviation from the plan's `*`-repeated design and
# left a real gap -- an independent verifier chained 13 wrappers and got
# past the depth<=3 cap live. The catastrophic-backtracking risk that
# motivated the bound is real for a naive `(?:(?:sudo|env)\s+(?:\S+\s+)*)*`
# (a wrapper word also matches the inner generic token, so the two `*`s
# compete for the same input and multiply out) -- but the fix for that is to
# remove the ambiguity, not cap the length. The inner flag-scan below
# excludes anything that matches a wrapper word via a negative lookahead, so
# any given token is always unambiguously "the next wrapper" or "a flag",
# never a choice between the two. That makes the whole prefix scan O(n) with
# no backtracking blowup, so both axes go back to genuinely unbounded,
# matching the plan ("env -u X FOO=bar sudo nice -n 10 command env claude -p x"
# now anchors regardless of chain length).
# Wrappers whose own flags may take a space-separated value before the wrapped
# command (an attached value, "-c3" / "-oL" / "--signal=KILL", is one token and
# needs no case). timeout/gtimeout also take one DURATION positional; that is
# handled where the wrapper is unwrapped. setsid takes bare flags only; exec's
# `-a name` is the one value flag (GH #227: it hid the wrapped command).
# Open-ended by nature: a wrapper missing here and from _RUN_WRAPPERS (GH #566 added flock, watch,
# strace, ...) still hides its command; the lists cover the ones an everyday one-liner uses.
FLAG_VALUE_WRAPPERS = {
    "nice": ("-n", "--adjustment"),
    "ionice": ("-c", "-n", "--class", "--classdata"),
    "stdbuf": ("-i", "-o", "-e", "--input", "--output", "--error"),
    "timeout": ("-s", "-k", "--signal", "--kill-after"),
    "gtimeout": ("-s", "-k", "--signal", "--kill-after"),
    "exec": ("-a",),
}
PREFIX_WRAPPERS = ("env", "command", "nohup", "time", "sudo", "doas", "setsid", "rtk") + tuple(FLAG_VALUE_WRAPPERS)
# `builtin` runs the builtin after it (`builtin eval rm -rf x`) and takes no flags. It is unwrapped
# in the rule loop only: as a member of PREFIX_WRAPPERS it also feeds _SPAWN_ANCHOR_RE, whose greedy
# walk then crosses `&&` and lands on the LAST `claude` (`builtin cd /tmp && claude -p x && claude
# --version` stopped denying; GH #245's overlapping scan now covers that shape too, and a
# wider PREFIX_WRAPPERS still changes the walk for every other consumer).
_UNWRAP_ONLY = ("builtin",)
# GH #216: `rtk` runs the command after it. `rtk proxy <cmd...>` executes its args as an argv;
# `rtk err|test|summary <args>` and `rtk run <args>` join the args and run them through `sh -c`
# (so one quoted string, or a quoted `;`, is a shell command line: verified live with touch);
# `rtk run -c <body>` is a shell body. Every other rtk verb (find, git, ls, psql, ...)
# dispatches to the real tool of that name, so it is classified as that tool.
_RTK_RUNNERS = ("proxy",)
_RTK_SHELL_RUNNERS = ("err", "test", "summary")
# GH #566: more programs that run the command after them, unwrapped in the rule loop only (as `builtin` is):
# a member of PREFIX_WRAPPERS would also widen the spawn-anchor walk, which runs on a time budget. A subagent's
# claude spawned through one of them is denied per window instead (see _SPAWN_WINDOW_FLAGS).
# name -> (flags that take the next word as their value, positionals between the flags and the command,
#          flags whose value is a shell command line, whether the remaining words are joined into one).
_RUN_WRAPPERS = {
    "flock": (("-w", "--wait", "--timeout", "-E", "--conflict-exit-code"), 1, ("-c", "--command"), False),
    "caffeinate": (("-t", "-w"), 0, (), False),
    "xcrun": (("-sdk", "--sdk", "-toolchain", "--toolchain", "-log"), 0, (), False),
    "chronic": ((), 0, (), False), "unbuffer": ((), 0, (), False),
    "strace": (("-o", "-e", "-p", "-s", "-u", "-E", "-a", "-b", "-I", "-O", "-P", "-S", "-X"), 0, (), False),
    "ltrace": (("-o", "-e", "-p", "-s", "-u", "-a", "-n", "-A", "-D", "-F", "-l", "-x"), 0, (), False),
    "watch": (("-n", "--interval", "-q", "--equexit"), 0, (), True),  # watch runs `sh -c "<words>"`
    "script": (("-E", "--echo", "-o", "--output-limit", "-T", "--log-timing", "-I", "--log-in",
                "-O", "--log-out", "-B", "--log-io", "-m", "--logging-format"), 0, ("-c", "--command"), False),
    "su": (("-g", "--group", "-G", "--supp-group", "-s", "--shell", "-w", "--whitelist-environment"), 0,
           ("-c", "--command", "-C", "--session-command"), None),  # su's words are a user, not a command
    "parallel": (("-j", "--jobs", "-S", "--sshlogin", "-P", "--max-procs", "-n", "--max-args", "-N",
                  "--joblog", "--results", "--delay", "--timeout", "-a", "--arg-file"), 0, (), False),
    "npx": (("-p", "--package"), 0, ("-c", "--call"), False), "bunx": (("-p", "--package"), 0, (), False),
    # GH #662: `busybox [--] APPLET args` runs the applet (rm, dd, mkfs.ext2, find, sh, ...); toybox likewise.
    **{_bb: ((), 0, (), False) for _bb in ("busybox", "busybox.static", "busybox-static", "toybox")},
    # GH #676: each stops at its first non-option word (checked live on util-linux 2.39 and coreutils 9.4,
    # and on runit 2.1.2's chpst and daemontools 0.76's setuidgid). An optional value (nsenter's -m -r -w
    # -W and its other "::" letters) can only be attached, so it is no value flag here. taskset -p takes a
    # pid, not a command. Bundled short flags and abbreviated long options are GH #709 for every wrapper.
    "chroot": (("--userspec", "--groups"), 1, (), False),  # NEWROOT, then the command
    "taskset": ((), 1, (), False),  # the mask or cpu list (-c only changes how it is read)
    "unshare": (("-S", "--setuid", "-G", "--setgid", "-R", "--root", "-w", "--wd", "--map-user", "--map-group",
                 "--map-users", "--map-groups", "--propagation", "--setgroups", "--monotonic", "--boottime"),
                0, (), False),
    "nsenter": (("-t", "--target", "-S", "--setuid", "-G", "--setgid"), 0, (), False),
    "chpst": (tuple("-" + c for c in "uUbemdopfcrt/nlL"), 0, (), False),  # runit's getopt string
    "setuidgid": ((), 1, (), False),  # the account, then the command
}
# GH #662: the walks with their own wrapper list (xargs, find -exec, a shell reading stdin) read past these too.
_BUSYBOX_NAMES = ("busybox", "busybox.static", "busybox-static", "toybox")
_STEP_WRAPPERS = PREFIX_WRAPPERS + _BUSYBOX_NAMES
def _past_run_prefix(w, i=0):
    # GH #674: the index of the program word in w[i:] past assignments and every wrapper the rule loop
    # unwraps: PREFIX_WRAPPERS with their value options (sudo's, env's, FLAG_VALUE_WRAPPERS), timeout's
    # DURATION, builtin, busybox, and _RUN_WRAPPERS with their value options and positionals. None when a
    # wrapper runs a body of its own instead (flock -c, su -c, script -c, env -S) or no program follows.
    # Self-contained: the heredoc strip calls it (via _reads_stdin_shell) before the rule loop's helpers exist.
    while i < len(w):
        t = w[i]
        b = t.rsplit("/", 1)[-1]
        if re.fullmatch(r"[A-Za-z_]\w*=.*", t):
            i += 1
            continue
        if b in PREFIX_WRAPPERS or b in _UNWRAP_ONLY or b in _BUSYBOX_NAMES:
            # the value options of _SQL_STAGE_WRAPPERS (sudo's full list) and FLAG_VALUE_WRAPPERS, not a third copy
            vals = set(FLAG_VALUE_WRAPPERS.get(b, ())) | set(_SQL_STAGE_WRAPPERS.get(b, ()))
            i += 1
            while i < len(w) and w[i].startswith("-") and len(w[i]) > 1:
                if b == "env" and w[i].split("=", 1)[0] in ("-S", "--split-string") or b == "env" and w[i].startswith("-S"):
                    return None
                done = w[i] == "--"
                i += 2 if w[i] in vals else 1
                if done:
                    break
            if b in ("timeout", "gtimeout") and i < len(w):
                i += 1  # the DURATION positional
        elif b in _RUN_WRAPPERS:
            vals, npos, bodies, join = _RUN_WRAPPERS[b]
            i += 1
            while i < len(w) and w[i].startswith("-") and len(w[i]) > 1:
                if w[i].split("=", 1)[0] in bodies:
                    return None
                done = w[i] == "--"
                i += 2 if w[i] in vals else 1
                if done:
                    break
            if join is None:
                return None  # su: a user, not a command
            i += npos  # watch (join) runs `sh -c "<words>"`, whose first word is still the program
        else:
            return i
    return None

# GH #668: the heredoc scan runs before the _CMD_LEN_CAP deny and a timeout allows, so a command over the
# cap skips it and is denied by that cap unchanged. GH #674: it runs here, past the wrapper tables, because
# its stdin-shell check (_reads_stdin_shell) walks them.
_SQL_BLANKING[0] = _sql_blanking_allowed(d["tool_input"].get("command", ""))
cmd = d["tool_input"].get("command", "")
cmd = _strip_heredocs(cmd, _KEPT_BODY_ENDS) if len(cmd) <= _CMD_LEN_CAP else cmd
# A package runner's package names map to the program they install (`npx @anthropic-ai/claude-code -p x`).
_PKG_PROGRAMS = {"claude-code": "claude"}
_SPAWN_WINDOW_FLAGS = ("-p", "--print", "--agent", "--bg", "--worktree")
# Reserved words that open a command position inside a compound statement
# ("for x in a; do rm -rf y; done": the segment after ";" starts with "do"), so
# the real argv0 comes right after them. Stripped at segment start only, never
# scanned for inside arguments, so `echo do rm -rf x` stays an echo. The same
# statement split over lines was already denied, only the ";" spelling leaked.
# Shared by the token windows (below) and the spawn anchor.
SHELL_KEYWORDS = ("!", "if", "elif", "then", "else", "do", "while", "until", "coproc")
# A wrapper word must be followed by whitespace, in the lookahead too: with a bare
# \b a token that only STARTS with one ("timeout=30", "exec-bot") is neither a
# wrapper nor an ordinary token, the regex dead-ends and the anchor never fires.
# GH #248: `xargs claude -p x` runs claude. xargs is a wrapper for the spawn anchor only: adding it
# to PREFIX_WRAPPERS would change the unwrap loop and every other consumer of that list.
# GH #320: a wrapper written as a path (`/usr/bin/env claude -p x`) runs the same program; the rule
# loop compares basenames, this anchor matched the bare word only. The prefix is one plain word that
# never starts with `-` and holds no `=`, `<` or `>`, so a token is a path wrapper, a flag or an
# assignment, never two of them, and the walk stays unambiguous (same prefix as subagent-git-guard.py).
_WRAPPER_ALT = r"(?:(?!-)[^\s;&|()<>=]*/)?(?:" + "|".join(PREFIX_WRAPPERS + ("xargs",)) + r")(?=\s)"
_WRAPPER_PREFIX = r"(?:" + _WRAPPER_ALT + r"\s+(?:(?!" + _WRAPPER_ALT + r")\S+\s+)*)*"
# GH #248: the greedy walk lands on the LAST claude (`time claude -p x; claude --version` anchored
# only the second). The lazy twin (`*?`) lands on the FIRST; it runs as one more last pass, so it
# only adds anchors.
_WRAPPER_PREFIX_LAZY = r"(?:" + _WRAPPER_ALT + r"\s+(?:(?!" + _WRAPPER_ALT + r")\S+\s+)*?)*"
_KEYWORD_PREFIX = r"(?:(?:" + "|".join(re.escape(k) for k in SHELL_KEYWORDS) + r")\s+)*"
# GH #245: an overlapping scan, `(?=(...))` read through m.end(1). The wrapper walk crosses
# `;` / `&&` / newline to the LAST `claude` (`time ls; claude -p x; claude --version`), and a plain
# finditer resumed after that match, so the earlier spawn was never scanned. Where finditer
# matched, the inner regex finds the same match, so this only adds anchors. The overlapping scan is
# quadratic on long padded commands and a timed-out hook allows, so the plain scan (develop's exact
# behaviour) runs where it always did and the overlapping one runs last, after every rule allowed:
# a command develop denied is denied just as fast as before.
# GH #248: `{ claude -p x; }` -- a brace group opens a command position (`{` then a blank).
# GH #322 (#318's shape in subagent-git-guard.py): zsh also runs a brace group with no blank after
# `{` (`{claude -p x;}`, `(){claude -p x;}`), and the Bash tool runs zsh, so a glued `{` that starts
# a word opens one too (any deny wins). Not `x{claude`, `${claude` or `}{claude`, which zsh does not run.
# GH #339: `builtin` before a wrapper runs it (`builtin command claude --agent x`, `builtin exec -a x claude
# --print x`). Not in the walk (see _UNWRAP_ONLY): one leading run of it instead, taken only when a wrapper
# word follows, as subagent-git-guard.py's _LEAD_CHAIN does. The run is one fixed word repeated and the
# lookahead makes its end unique, so it adds no split to the walk.
_SPAWN_LEAD = r"(?:(?:builtin[ \t]+(?:--[ \t]+)?)+(?=" + _WRAPPER_ALT + r"))?"
def _spawn_anchor_body(wrapper_prefix):
    # `(?!\s)` keeps the glued alternative disjoint from `{` + blank, so no `{` is walked twice.
    return (r"(?:^|[|;&()]|&&|\|\||\{(?=\s)|(?<![^\s;&|(){])\{(?!\s))\s*" + _KEYWORD_PREFIX + r"(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*" +
            _SPAWN_LEAD + wrapper_prefix + r"\\?(?:\S*/)?claude(?![-\w./])")
_SPAWN_ANCHOR_RES = (re.compile(r"(" + _spawn_anchor_body(_WRAPPER_PREFIX) + r")", re.MULTILINE),
                     re.compile(r"(?=(" + _spawn_anchor_body(_WRAPPER_PREFIX) + r"))", re.MULTILINE),
                     re.compile(r"(?=(" + _spawn_anchor_body(_WRAPPER_PREFIX_LAZY) + r"))", re.MULTILINE))
_SPAWN_FLAG_RE = re.compile(r"-p\b|--print\b|--agent\b|--bg\b|--background\b|--worktree\b|-w\b")
# Bypass hunt 2026-10-23 F1/F2: -w and --background are --worktree's and --bg's other spellings, and
# the Bash tool has no TTY, so `claude <prompt>`, `<input> | claude` and `claude < file` run headless
# exactly like -p. A version or help word anywhere in argv exits before a session starts (2.1.310).
# The flag scan above reads every anchor; the prompt/stdin reading (_claude_starts_session) only an
# anchor outside quotes, since a quoted `;` or `|` in a commit message opens an anchor here too, and
# `-m "a; claude handles it"` must not read `handles` as a prompt.
_SPAWN_INFO = ("--version", "-v", "--help", "-h")
# `claude --help`'s Commands that start no session (2.1.310). Not `agents`, `attach`, `respawn` or
# `ultrareview`: each one dispatches, opens or restarts a session.
_CLAUDE_NO_SESSION_SUBS = frozenset({"auth", "auto-mode", "config", "doctor", "gateway", "import", "install",
                                     "kill", "logs", "mcp", "migrate-installer", "plugin", "plugins", "purge",
                                     "rm", "setup-token", "stop", "update", "upgrade"})
_SPAWN_WORDS_CAP = 1024
_SPAWN_OUT_REDIR_RE = re.compile(r"\d*(?:&>>?|>>?&?|>\|)\s*(?:\"[^\"]*\"|'[^']*'|[^\s;&|()<>]+)?")
# GH #157: an ODD backslash run directly before a quote escapes that quote
# in real bash (`claude \" ; othertool -p x` -- the `"` is a literal argument
# character, not a string opener), so it is captured as one literal token
# here, ahead of the quoted-span alternatives that would otherwise start a
# span at that quote and swallow the real ";" after it. An even run
# (`\\"a ; b"`) leaves the quote live, falls through to the run + span
# alternatives below, and still swallows the ";" -- the deny direction.
_SPAWN_TOKEN_RE = re.compile(
    "\\\\(?:\\\\\\\\)*[\"" + SQ + "]|"
    "\"(?:[^\"\\\\]|\\\\.)*\"|" + SQ + "[^" + SQ + "]*" + SQ + "|\\\\+|.", re.DOTALL
)
# C1 (harness gap-audit, 2026-09-20): the outer loop over every anchor match
# times an unbounded inner token scan is O(anchors x remaining-length) -- an
# unclosed "(" after each anchor keeps depth > 0 so the inner scan never
# breaks early, consuming the rest of the string every single time. Live-
# reproduced: 6,000 anchors in a 48,000-char command (well under
# _CMD_LEN_CAP's 150,000) took 22s, far past this gate's own 8s hooks.json
# PreToolUse timeout -- and Claude Code's own hooks reference confirms a
# timed-out PreToolUse command hook lets the tool call continue, so a slow
# enough payload silently bypasses this entire check. Same budget magnitude
# and shared-counter pattern as _blank_substitutions's _DEPTH_SCAN_BUDGET
# above; "return True" (deny) on exhaustion is this file's own documented
# safe direction -- widening the scan can only over-deny, never under-deny.
_SPAWN_SCAN_BUDGET = 2_000_000
# GH #246 (found while fixing the same hole in subagent-git-guard.py): the token budget above
# never sees the regex itself. Every anchor scan tries each command start (a separator or a
# line start) and walks on past a wrapper word or assignment, so its cost is about starts x
# length, and the #245 overlapping pass hits it at every start. `env ; ` x 8000 (48 KB) in front
# of a hidden `claude -p` took 10 s, past the 8 s timeout, which allows. Every call charges that
# bound to one counter shared by the plain, body and overlapping scans; over budget denies (the
# same safe direction) with its own message. Real subagent commands stay far under it; only a
# rare 20 KB+ script is refused.
_SPAWN_ANCHOR_BUDGET = 26_000_000
_spawn_anchor_work = 0
_spawn_over_budget = False

# GH #322 (#317's fix in subagent-git-guard.py): outside quotes a shell drops a backslash before an
# ordinary character, so `cl\aude -p x`, `e\nv claude -p x` and `claude --pri\nt x` spawn, but this
# anchor and _SPAWN_FLAG_RE read the raw text. Inside each word the backslash is dropped before the
# scan (freed blanks go to the word's front, so the length holds). A pair stays (`\\` is a literal
# backslash), and so does a backslash before a character it makes literal (`\{`, `\;`, `\"`): dropping
# it there would change what the text means. Inside quotes the drop can only add an anchor.
_SPAWN_WORD_RE = re.compile(r"[^\s;&|()<>]+")
_SPAWN_ESC_RE = re.compile(r"\\(.)")
_SPAWN_KEEP_ESCAPED = set("\\{}=#$'\"`~*?[]!")

# GH #344 (subagent-git-guard.py's _QWORD_RE, same pattern, a test checks they match): a shell also
# removes the quotes inside a word, so `"claude" -p x`, `cl'a'ude -p x`, `"env" claude -p x` and
# `claude '-'p x` spawn. A word made only of command-word characters and quoted runs of them (`$'..'`
# and `$".."` too) is joined back to its letters, blanks to its front, after the backslash drop. A
# quoted `=` is a command name, not an assignment, so it is not a word character. This anchor reads raw
# text, where a quoted `;` already opens a command start, so joining inside quotes can only add an anchor.
# Joining can glue a flag to its neighbour (`claude -p"x"` is `-px`), so when it changed the text the
# unjoined text is scanned too, and either reading denies.
_SPAWN_QWORD_RE = re.compile(r"(?<![^\s;&|()<>{])(?:[\w./-]|\\[\w./-]|\$?\"[\w./-]*\"|\$?'[\w./-]*')+(?![^\s;&|()<>}])")
_SPAWN_QMARK_RE = re.compile(r"\$?[\"']|\\(?=[\w./-])")

def _spawn_join_quoted(m):
    w = m.group()
    j = _SPAWN_QMARK_RE.sub("", w)
    return " " * (len(w) - len(j)) + j

def _spawn_drop_escapes(c):
    def word(m):
        w = m.group()
        if "\\" not in w:
            return w
        u = _SPAWN_ESC_RE.sub(lambda e: e.group(0) if e.group(1) in _SPAWN_KEEP_ESCAPED else e.group(1), w)
        return " " * (len(w) - len(u)) + u
    return _SPAWN_WORD_RE.sub(word, c)

def _nested_spawn(c, overlap):
    c = _spawn_drop_escapes(c)
    j = _SPAWN_QWORD_RE.sub(_spawn_join_quoted, c)
    return _nested_spawn_text(j, overlap) or (j != c and _nested_spawn_text(c, overlap))

def _charge_spawn_anchor(c):
    # GH #246: charge one anchor scan of c (about starts x length) to the shared counter. True, with
    # _spawn_over_budget set, once the counter is past _SPAWN_ANCHOR_BUDGET.
    global _spawn_anchor_work, _spawn_over_budget
    _spawn_anchor_work += sum(c.count(ch) for ch in "\n;&|({") * len(c)
    if _spawn_anchor_work > _SPAWN_ANCHOR_BUDGET:
        _spawn_over_budget = True
        return True
    return False

# The statement an anchor opens runs to the first top-level separator.
# Deep-audit 2026-09-07: a bare separator (&;|\n) inside a paren/backtick
# group (command substitution, process substitution, a subshell) is NOT a
# top-level statement separator for the outer command -- real bash parses
# the whole group as one unit regardless of what's inside it. depth tracks
# "(" / ")" nesting (clamped at 0, so a stray unmatched ")" can't go
# negative and mask a later real "("); in_backtick toggles on each "`".
# While either is active, a separator only ends the CURRENT token's
# ordinary handling, never the scan -- widening the scan region is the
# safe direction for a deny gate.
#
# Backslashes outside quotes pair up two-at-a-time in real bash: a RUN of
# N consecutive backslashes escapes the following character only if N is
# odd (the trailing, unpaired backslash); an even N means every backslash
# is a literal and the following character keeps its normal meaning.
# _SPAWN_TOKEN_RE's own "\\+" alternative captures a whole run as one
# token so its length can be checked directly, rather than matching one
# backslash at a time (which can't tell an odd run from an even one).
# Two Codex-validator rounds, deep-audit 2026-09-07, both reproduced
# live: (1) `claude --version \( ; othertool -p` was denied -- an odd
# (single) escaped "(" is a literal argument character, not a subshell
# opener, but got miscounted as depth+=1, swallowing the real ";" and
# crediting othertool's -p back to claude. (2) a first, simpler fix
# (fixed-length "\\X" pairing, no parity check) then ALLOWED `claude
# \\`printf x; printf y` -p evil` -- an EVEN (double) backslash before a
# backtick leaves the backtick unescaped and live in real bash (the pair
# is just one literal backslash), so it really does open a command
# substitution carrying -p back to claude; treating the backtick as
# escaped there was a false ALLOW, a real bypass, not just an
# over-cautious false DENY. Parity tracking fixes both directions.
def _spawn_statement(tail, work):
    # (text of the statement at the start of tail, work); text is None once the shared token count
    # `work` passes _SPAWN_SCAN_BUDGET.
    buf, depth, in_backtick = [], 0, False
    escape_next = False    # trailing backslash of an odd-length run
    after_backslash = False  # any backslash run, odd or even, just seen
    for tok in _SPAWN_TOKEN_RE.finditer(tail):
        work += 1
        if work > _SPAWN_SCAN_BUDGET:
            return None, work
        t = tok.group()
        if t and t.count("\\") == len(t):
            buf.append(t)
            escape_next = len(t) % 2 == 1
            after_backslash = True
            continue
        if t == "\n" and (escape_next or after_backslash):
            # Any backslash run right before a real newline keeps the
            # scan going, regardless of parity -- this file's own
            # deliberate safe-direction precedent for a deny gate (an
            # even count is not a true continuation in real bash, but
            # treating it as one is the safe direction: it can only
            # widen the scan, never narrow it past a real spawn).
            buf.append(t)
            escape_next = after_backslash = False
            continue
        if escape_next:
            buf.append(t)
            escape_next = after_backslash = False
            continue
        after_backslash = False
        if t == "(":
            depth += 1
        elif t == ")":
            depth = max(0, depth - 1)
        elif t == "`":
            in_backtick = not in_backtick
        elif len(t) == 1 and t in "&;|\n" and depth == 0 and not in_backtick:
            break
        buf.append(t)
    return "".join(buf), work


_SPAWN_SESSION_SEEN = {}  # the three anchor passes, joined and plain text, re-read the same statements

def _claude_starts_session(stmt, piped):
    key = (stmt[:_SPAWN_WORDS_CAP + 1], piped)
    r = _SPAWN_SESSION_SEEN.get(key)
    if r is None:
        r = _SPAWN_SESSION_SEEN[key] = _claude_words_start_session(stmt, piped)
    return r

def _claude_words_start_session(stmt, piped):
    # F1: stmt is the raw text after an unquoted `claude`. A `<` stdin (not `<(`) or a pipe in is the
    # prompt; so is any word that is not an option (an option's value too: over-denies `claude --model
    # sonnet`, which has no prompt and fails anyway), unless a version or help word exits first, or
    # the first word is a subcommand that starts no session (`claude --model mcp x` is a prompt).
    # Only a prefix is read: every anchor reads its own statement, and an unclosed `(` makes that the
    # rest of the command each time. A cut statement that shows no version or help word is a spawn.
    cut = len(stmt) > _SPAWN_WORDS_CAP
    stmt = stmt[:_SPAWN_WORDS_CAP]
    depth = 0
    for tok in _SPAWN_TOKEN_RE.finditer(stmt):  # a `)` closing `$(claude ...)` ends claude's words
        depth += (tok.group() == "(") - (tok.group() == ")")
        if depth < 0:
            stmt, cut = stmt[:tok.start()], False
            break
    # A version or help word inside $(..) or `..` is that command's, not claude's.
    text = _SPAWN_OUT_REDIR_RE.sub(" ", stmt.replace("<(", " ("))
    while True:
        t2 = re.sub(r"\$\([^()]*\)|`[^`]*`", " X ", text)
        if t2 == text:
            break
        text = t2
    try:
        words = shlex.split(text, comments=True)
    except ValueError:
        words = None
    if words and any(t in _SPAWN_INFO for t in words):
        return False
    if words is None or cut or re.search(r"<(?!\()", stmt):
        return True
    if words and words[0] in _CLAUDE_NO_SESSION_SUBS:
        return False
    for i, t in enumerate(words):
        if t == "--":
            return i + 1 < len(words) or piped
        if not (t.startswith("-") and len(t) > 1):
            return True
    return piped

def _nested_spawn_text(c, overlap):
    global _spawn_over_budget
    if _charge_spawn_anchor(c):
        return True
    work = 0  # shared across every anchor's scan, never reset per-anchor -- see _SPAWN_SCAN_BUDGET above
    mask = None
    spans = None
    for m in _SPAWN_ANCHOR_RES[overlap].finditer(c):
        stmt, work = _spawn_statement(c[m.end(1):], work)
        if stmt is None:  # GH #798: a spent scan budget denies as "too dense", not as a spawn it did not find
            _spawn_over_budget = True
            return True
        if _SPAWN_FLAG_RE.search(stmt):
            return True
        if mask is None:
            mask = _quote_mask(c)
        if mask[m.end(1) - 1]:
            continue
        a, lead = m.start(1), m.group(1)
        lead_words = _spawn_lead_words(lead)
        if lead_words is None and lead[:1] == ")" and "|" in c:
            # GH #820 item 3: a case arm's `)` in a piped case (`echo hi | case a in a) claude;; esac`), never a `$(..)`
            # close (`echo $(date) claude started`).
            if spans is None:
                spans = _piped_compound_spans(c, mask)
            o = next((o for o, e, kw in spans if kw == "case" and o <= a < e), None)
            p = -1 if o is None else c.rfind("(", o, a)
            if o is not None and (p < 0 or c[p - 1] not in "$<>("):  # not $(..), $((..)), <(..), >(..)
                lead_words = _spawn_lead_words(lead[1:])
        if lead_words is None:
            continue
        # A pipe in: `|` that is not `||`, or `|&`, up to a `(` or `{` group open; xargs hands its input
        # over as words.
        sep = re.match(r"[|;&(){\s]*", lead).group()
        piped = _pipe_before(c, a + len(sep), mask) or "xargs" in lead_words  # GH #810: | \<newline>, | # comment
        # GH #820 item 4: `>(claude)` reads what is written to it. Item 3: a pipe into a compound command feeds every
        # claude in it (`echo hi | case a in a) claude;; esac`, `| while read l; do claude; done`).
        if not piped and c[a] == "(" and a and c[a - 1] == ">" and not mask[a - 1]:
            piped = True
        if not piped and "|" in c:
            if spans is None:
                spans = _piped_compound_spans(c, mask)
            piped = any(o <= a < e for o, e, _ in spans)
        if _claude_starts_session(stmt, piped):
            return True
    return False

_COMPOUND_KW_RE = re.compile(r"(?<![^\s;&|()])(case|if|while|until|for|select|esac|fi|do|done)(?![^\s;&|()<>])")
_COMPOUND_OPEN = ("case", "if", "while", "until", "for", "select")
_KW_LEAD_WORDS = ("then", "do", "else", "elif", "!", "{", "time", "fi", "esac", "done")  # `fi done` closes both

def _at_command_position(c, i):
    j = i
    while j and c[j - 1] in " \t":
        j -= 1
    if not j or c[j - 1] in ";&|(){}\n":  # `{ :; } done` closes too (GH #816 review)
        return True
    w = re.search(r"\S+$", c[max(0, j - 8):j])
    return w is not None and w.group() in _KW_LEAD_WORDS

def _piped_compound_spans(c, mask):
    # GH #820 item 3: the (start, end) of each compound command (case, if, while, until, for, select) a pipe feeds, to
    # its matching esac / fi / done. Keywords are counted at a command position outside quotes and comments; one this
    # misses can end a span early (a gap) or, a close missed, run it to the end. A span with no close runs to the end of the text.
    if not re.search(r"(?<![\w-])(?:case|if|while|until|for|select)(?![\w-])", c):
        return []
    # One pass with a stack: case / if open at once, while / until / for / select at their `do`.
    out, stack, pending = [], [], []
    for m in _COMPOUND_KW_RE.finditer(c):
        w, at = m.group(1), m.start()
        if mask[at] or not _at_command_position(c, at):
            continue
        if w in _COMPOUND_OPEN and c[m.end():m.end() + 1] == ")":
            continue  # a case pattern (`a|if)`), not a command (GH #816 review)
        if w in _COMPOUND_OPEN:
            e = (at, w, _pipe_past_comments(c, at, mask))  # a walk back from at: no scan of the text before it
            (stack if w in ("case", "if") else pending).append(e)
        elif w == "do":
            stack.append(pending.pop() if pending else (at, w, False))
        elif stack:
            o, kw, piped = stack.pop()
            if piped:
                out.append((o, m.end(), kw))
    out.extend((o, len(c), kw) for o, kw, piped in stack + pending if piped)
    return out

_RAW_PIPE_RE = re.compile(r"(?<!\|)\|&?(?:[\s({]|\\\n)*$")  # develop's reading: | \<newline> (GH #810)

def _pipe_before(c, end, mask):
    # True when a pipe (`|` or `|&`, not `||`) is the last thing before c[end], past blanks, a `(` or `{` group open,
    # backslash-newlines and, beyond develop's raw reading (kept whole), comments (GH #810: `| # feed\n claude`).
    # A `>|` redirect or a case / [[ =~ pattern `|` stays a pipe (GH #810 item 3, kept deny): an alias (bash expands
    # one even on a reserved word, and the shell snapshot turns expand_aliases on), a backtick or an expansion can
    # make the text bash parses differ from the text read (GH #812 reviews 1-9).
    return _RAW_PIPE_RE.search(c, 0, end) is not None or _pipe_past_comments(c, end, mask)

def _pipe_past_comments(c, end, mask):
    j = end
    while j:
        ch = c[j - 1]
        if ch in " \t\n({":
            j -= 1
        elif ch == "\\" and c[j:j + 1] == "\n" and not mask[j - 1]:  # a comment's last `\` continues nothing
            j -= 1
        elif mask[j - 1]:
            k = j - 1  # the masked run's start: a comment runs from its `#` to the line end
            while k and mask[k - 1]:
                k -= 1
            esc_nl = c[k] == "\n" and k and c[k - 1] == "\\"  # a backslash-newline just before the comment
            h = k + 1 if esc_nl else k
            if c[h:h + 1] != "#" or (h and c[h - 1] not in " \t\n;&|()") or c[j:j + 1] not in ("\n", ""):
                return False  # a quoted or escaped word, not a comment
            if re.search(r"\|&?[ \t]*$", c[h:j]):
                return True  # a comment that ends in a pipe: develop's raw reading took it as one, kept
            j = k - 1 if esc_nl else h
        else:
            break
    if j and c[j - 1] == "&" and c[j - 2:j - 1] == "|":
        j -= 1
    return bool(j) and c[j - 1] == "|" and c[j - 2:j - 1] != "|"

def _spawn_lead_words(lead):
    # The wrapper names in an anchor's text before `claude`, or None when that text holds a word no
    # wrapper explains: the anchor's walk skips any words after a wrapper (`time rg claude src/`), fine
    # for the flag scan but not for reading claude's words as a prompt. Explained: an assignment, a
    # keyword, a wrapper, a dash word after a wrapper and the one word after that dash word (its value,
    # if it takes one: `env -C /tmp`, `sudo -p pw:`, `timeout -s KILL`), and timeout's duration.
    words = lead.replace("{", " ").replace("(", " ").split()[:-1]  # the last word is claude
    names, prev, after_dash = [], None, False
    for t in words:
        t = t.lstrip("|&;")
        if not t or re.match(r"[A-Za-z_]\w*=", t):
            continue
        b = t.rsplit("/", 1)[-1]
        if b in SHELL_KEYWORDS or b in ("builtin", "--"):
            continue
        if b in PREFIX_WRAPPERS or b == "xargs":
            prev, after_dash = b, False
            names.append(b)
            continue
        if prev and t.startswith("-"):
            after_dash = True
            continue
        if after_dash:
            after_dash = False
            continue
        if prev in ("timeout", "gtimeout") and re.fullmatch(r"[\d.]+[smhd]?", b):
            continue
        return None
    return names

_SPAWN_DENY_REASON = ("a subagent may not spawn a nested Claude Code session via Bash (claude with a prompt "
                      "or piped input, -p/--print, --agent, --bg/--background, -w/--worktree) -- only the "
                      "main session dispatches")

# GH #593 / #661: the rules a reading may decide with, or None for all: a deny by any other rule (or a
# structural one) ends the window unreported, and any other ask is dropped.
_ONLY_RULE = [None]
# GH #661: in the enforced view pass, a deny by another rule that has an id returns instead of ending the window,
# so the enforced rule further on in the same window is still reached. A structural deny (no id: a depth limit,
# the handover budget, an untokenizable body) denies there, as it does in the main reading: the text cannot be
# read safely. The pass runs no spawn check (that is the main reading's).
_ONLY_RULE_PASS_ON = [False]
def _deny_nested_spawn():
    if _ONLY_RULE[0] and not _ONLY_RULE_PASS_ON[0]:
        raise _ViewStop
    if _ONLY_RULE_PASS_ON[0]:
        return  # the enforced view pass reads only the _VIEW_ENFORCED rules: no spawn scan, so no spawn-scan budget (review 8)
    _disarm()
    if _spawn_over_budget:
        print("[mh:gate] BLOCKED: subagent command is too long or too dense to check safely; write it "
              "to a file with the Write tool and run the file, or split it into smaller commands",
              file=sys.stderr)
    else:
        print("[mh:gate] BLOCKED: " + _SPAWN_DENY_REASON, file=sys.stderr)
    journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"))
    sys.exit(2)

# GH #588: a command name that is a substitution printing claude (`$(echo claude) -p x`, `` `which
# claude` ``, `${C:-claude}`), at a command position (past assignments and wrappers) outside quotes and
# comments. Its statement is read as claude's words, as an anchored `claude` is: a spawn flag, a prompt
# word, piped or `<` input. `$(echo cla)ude` (a name split across text and a substitution) is a gap.
_SUBST_CLAUDE = (r"\$\([^()]*?(?<![\w.-])claude(?![\w.-])[^()]*\)|`[^`]*?(?<![\w.-])claude(?![\w.-])[^`]*`"
                 r"|\$\{\w+:?[-=+][\"']?(?:[^\s}]*/)?claude[\"']?\}")
# A command position: a statement start (also after `)`, as in `case x in x) ...` or `x=$(..) cmd`) or a
# find action's command; then keywords, assignments, `eval` and wrappers. The substitution must end the
# word (`$(echo claude)x` runs claudex). A double-quoted shell `-c` / eval body, where the outer shell runs
# the substitution, is read again as its own text (_DQ_BODY_RE).
_SUBST_SPAWN_RE = re.compile(r"(?:^|(?<=[;&|()\n{])|(?<=-exec )|(?<=-execdir )|(?<=-ok )|(?<=-okdir ))"
                             r"[ \t]*" + _KEYWORD_PREFIX + r"(?:[A-Za-z_]\w*=\S*[ \t]+)*(?:eval[ \t]+)?(?:" + _WRAPPER_ALT
                             + r"[ \t]+(?:-\S*[ \t]+)*)*\"?\\?(" + _SUBST_CLAUDE + r")\"?(?=[\s;&|)<>\"]|$)", re.MULTILINE)

# A shell (its name starting a word, `\bash` too, so a long word is not rescanned from every position) with
# up to 32 options before its `-c` cluster, each with at most one value word (`-o pipefail`, `--rcfile f`,
# `--norc`, `+e`, `-lc`; bounded and option-led, so a statement of many `bash` words stays linear: a 33rd
# option before `-c` is a known gap; an unbounded scan took 23-60 s at 140 KB, past the hook timeout) and an optional `--`, or `eval`; then a double-
# quoted body, which may hold a `$(...)` with quotes of its own.
_DQ_BODY_RE = re.compile(r"(?:(?<![^\s;&|(){])\\?(?:[^\s;&|()\"'/]*/)*(?:bash|sh|zsh|dash|ksh|ash|hush)"
                         r"(?:[ \t]+[-+]{1,2}[A-Za-z][^\s\"';&|]*(?:[ \t]+(?![-+])[^\s\"';&|]+)?){0,32}?"
                         r"[ \t]+[-+][A-Za-z]*c(?:[ \t]+--)?|(?<![\w./-])eval)[ \t]+\""
                         r"((?:\$\((?:[^()]|\([^()]*\))*\)|[^\"\\]|\\.)*)\"")

def _subst_spawn(c, depth=0):
    if "claude" not in c:
        return False
    if depth < 3:
        for b in _DQ_BODY_RE.finditer(c):
            if _subst_spawn(re.sub(r"\\([$`\"\\])", r"\1", b.group(1)), depth + 1):
                return True
    mask, work = None, 0
    for m in _SUBST_SPAWN_RE.finditer(c):
        if mask is None:
            mask = _quote_mask(c)
        # A substitution quoted only by its own word (`"$(echo claude)" -p x`) is still the command; one that
        # opens a longer quoted string (an eval / -c body, read by _DQ_BODY_RE above) is not.
        q = m.start(1) - 1
        if mask[m.start(1)] and not (c[q:q + 1] == '"' and (q == 0 or not mask[q - 1]) and m.group(0).endswith('"')):
            continue
        stmt, work = _spawn_statement(c[m.end():], work)
        pre = c[:m.start()].rstrip(" \t")
        piped = pre.endswith("|") and not pre.endswith("||")
        if stmt is None or _SPAWN_FLAG_RE.search(stmt) or _claude_starts_session(stmt, piped):
            return True
    return False

if ("agent_id" in d) and (_nested_spawn(cmd, False) or _subst_spawn(cmd)):
    _deny_nested_spawn()

# GH #337 shadow mode: a rule whose id is listed here only journals "would_deny"/"would_ask" (with
# the id and the command) and lets the call through, so a new rule can be measured on real work
# (/mh:gate-report) before it enforces; promote it by deleting its id. A constant in the gate's own
# source, never an env var, so a project's settings.json cannot shadow an enforced rule. Only a
# pattern rule (a `rule=` id at its call site) can be shadowed: a structural deny (length cap,
# unparsable text, budget, depth) has no id, since returning from it would run the very code it guards.
SHADOW_RULES = frozenset({"var-verb", "opaque-var-verb", "source-file", "brace-view"})
_SHADOW_LOGGED = set()  # (rule, decision) already journaled this run: window copies re-match a rule
# GH #336: the rule id of the view (another reading of the command, see _views) now being checked.
# Inside a view a verdict belongs to the matched rule and to the view's rule: either one being
# shadowed shadows it, journaled under the matched rule when that one is shadowed. A shadowed deny
# ends the view (_ViewStop). A structural deny (no rule id) never fires in a view: it is an artifact
# of the substituted text, so it ends the view too.
_VIEW = [None]
class _ViewStop(Exception):
    pass

# The rules a shadowed view still enforces; brace-view stays shadow for every other rule (GH #337). These rules
# must read the words bash builds, and no token reading keeps such a word whole (`--{r,} b` loses its `}`):
# rm's own (GH #661: `rm --{r,f} b` is `rm --r --f b`) and push's overwrite rules, send-pack included (GH #309:
# `--{force,force}`, `--{mirror,mirror}`, `:{main,main}`), and git's discard rules (GH #718: `git reset --{hard,hard}`
# was read only here, and allowed).
_VIEW_ENFORCED = {"brace-view": frozenset({
    "rm-rf", "rm-recursive", "rm-no-preserve-root",
    "git-push-force", "git-push-mirror", "git-push-delete-protected",
    "git-reset-hard", "git-clean-force", "git-checkout-discard", "git-restore", "git-stash-drop", "git-switch-force",
    "git-checkout-index-force", "git-read-tree-reset", "git-branch-force-delete", "git-branch-force-move-protected",
    "git-worktree-remove-force", "git-reflog-prune", "git-update-ref-delete-protected", "git-rm-force"}),
    # GH #767: rm's own rules read the value a plain NAME=value assignment puts back (`F=-rf; rm $F b`); every
    # other var-verb rule stays shadow until /mh:gate-report shows no false positive.
    "var-verb": frozenset({"rm-rf", "rm-recursive", "rm-no-preserve-root"})}

def _shadowed(rule, decision):
    if rule in _VIEW_ENFORCED.get(_VIEW[0], ()) and rule not in SHADOW_RULES:
        return False
    rule = next((r for r in (rule, _VIEW[0]) if r in SHADOW_RULES), None)
    if rule is None:
        return False
    if (rule, decision) not in _SHADOW_LOGGED:
        _SHADOW_LOGGED.add((rule, decision))
        journal(GATE_ID, d.get("tool_name"), "would_" + decision, d.get("session_id"),
                rule=rule, command=cmd[:300])
    return True

# Safe next steps a deny names (hint=). Each passes this gate and never names git stash. A step subagent-git-guard
# denies (reset --keep, clean -n) says "in the main session" (tests/hooks/test-gates-irrecoverable-2.sh checks both).
# The patch restores content with `git apply`, not the staged/unstaged split: re-stage after applying it.
# --binary: a plain diff writes only "Binary files differ" for a binary file. --no-textconv, --no-ext-diff, --no-color:
# a diff driver (git-crypt, a textconv) or forced color writes text that git apply cannot restore.
_SAVE_HINT = "or commit first, or save a patch with `git diff --binary --no-textconv --no-ext-diff --no-color HEAD > x.patch`"
_CHMOD_HINT = "or grant the narrowest mode needed (`chmod 755`, `chmod u+x`)"
# Set once a git -c / git config alias body is queued: its windows are checked later, outside the alias call.
# shortcut: it drops the hints of every later deny in the run too (the tail stays); tag windows if that matters.
_GIT_ALIAS_SCANNED = [False]

def deny(reason, rule=None, hint=None):
    if _ONLY_RULE[0] is not None and rule not in _ONLY_RULE[0]:
        if not _ONLY_RULE_PASS_ON[0]:
            raise _ViewStop
        if rule is not None:
            return
        if _VIEW[0] == "var-verb":
            # GH #767 review 5: var-verb's text holds values put back in place (`\$G` too), which can leave a quote
            # unbalanced where the shell's text is fine; a structural deny there only ends the window.
            raise _ViewStop

    elif _VIEW[0] and rule is None:
        raise _ViewStop
    if not (_ONLY_RULE_PASS_ON[0] and rule is None) and _shadowed(rule, "deny"):
        if _VIEW[0]:
            raise _ViewStop
        return
    if "confirm with user first" in reason:
        # A headless run has nobody to confirm: name a step the model can still take (2026-10-27 audit).
        # Inside a git -c / git config alias the verb's hint is wrong: the step is dropping the alias.
        if hint and not _GIT_ALIAS_SCANNED[0]:
            reason += ", " + hint
        if rule is None:  # every rule-less confirm deny is a tokenizer/complexity refusal
            reason += "; split it into simpler separate commands"
        reason += "; if nobody can confirm, skip this step, keep going on the rest, and list it for the user in your final report"
    _disarm()
    print("[mh:gate] BLOCKED: " + reason, file=sys.stderr)
    # A rule a shadowed view enforces is journaled under its own id, so the view's shadow record stays its own.
    journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"),
            rule=rule if rule in _VIEW_ENFORCED.get(_VIEW[0], ()) else _VIEW[0] or rule)
    sys.exit(2)

_ASKED = []
def ask(reason, rule=None):
    # Unlike deny(), doesn't exit immediately -- a later, more severe check in
    # the same run can still escalate to deny() (which does exit right away),
    # same "ask now, a worse finding can still override" shape config-write-guard.py
    # and codex-setup-guard.py's own emit_ask() already use. Emits at most once: a
    # window can be checked in several copies (compacted, brace-joined), and two
    # JSON objects on stdout are not valid JSON (GH #254 validator).
    # A shadowed ask is checked first and never touches _ASKED, so a later real ask still emits.
    # In a view (GH #336) an ask adds nothing once the command already asks.
    if (_ONLY_RULE[0] is not None and rule not in _ONLY_RULE[0]) or (_VIEW[0] and _ASKED) or _shadowed(rule, "ask") or _ASKED:
        return
    # Print before append (GH #771): a deadline signal between them then emits a second ask, invalid
    # output that onFailure blocks, instead of seeing _ASKED set and exiting with nothing printed (allow).
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    _ASKED.append(reason)
    journal(GATE_ID, d.get("tool_name"), "ask", d.get("session_id"), rule=_VIEW[0] or rule)

def delete_hint():
    # trash is not stock on macOS or Linux -- offer whichever CLI exists.
    import shutil
    t = next((c for c in ("trash", "trash-put") if shutil.which(c)), None)
    if t:
        return "use " + t + " instead"
    return ("no trash CLI on this machine — ask the user before a destructive "
            "delete, or install one (macOS: brew install trash; Linux: trash-cli)")

# Tokenize respecting quotes so quoted free text stays one token.
# ponytail: no command-substitution unwrapping (bash -c / eval get one level) -- habit-guard, not sandbox,
# add recursive unwrapping if a real bypass nests bash -c/eval more than one level deep.
# Newlines are command separators in bash but shlex eats them as whitespace,
# so a literal ";" is inserted after each real newline. A backslash-newline is
# a line continuation: both chars are removed entirely so the next token joins
# cleanly (a residual "\n--force" would miss the exact-match flag check).
# Inside a "#" comment the newline still ends the comment (a trailing backslash
# has no continuation effect there), so it still gets the separator. Comment
# and quote state are tracked char by char with backslash-escape parity (DQ is set beside SQ above).
# GH #233: shlex drops quotes, so a quoted operator-only argument (";", "&&", "|") would reach the
# window split as a bare separator and hide a later flag. At the closing quote, such a body is
# swapped for HASH_LIT (a wordchar, one nonflag token); the quotes stay.
_OP_CHARS = frozenset(";&|(){}")
def _mask_quoted_ops(out, qstart):
    body = out[qstart:-1]
    if body and all(ch in _OP_CHARS for ch in body):
        out[qstart:-1] = [HASH_LIT]
def _escaped_op_word_end(s, i):
    # End index of a run of escaped-operator pairs starting at s[i] that is a whole word, else 0.
    j, n = i, len(s)
    while j + 1 < n and s[j] == "\\" and s[j + 1] in ";&|()":
        j += 2
    return j if j > i and (j == n or s[j].isspace() or s[j] in ";&|)") else 0
# Quoted and comment spans copied verbatim, one char per `out` item (_mask_quoted_ops and the "#"
# word-start test read single items). Each takes the index just past the span's opener and returns
# the index just past its closer, or len(s) when the span is unterminated.
def _copy_comment(s, i, out, nl):
    # The newline ends the comment and is written as `nl`.
    j = s.find("\n", i)
    if j < 0:
        out.extend(s[i:])
        return len(s)
    out.extend(s[i:j])
    out.extend(nl)
    return j + 1

def _copy_squote(s, i, out, mask_from=None):
    # mask_from: where the body starts in `out`; a closed body is passed to _mask_quoted_ops.
    j = s.find(SQ, i)
    if j < 0:
        out.extend(s[i:])
        return len(s)
    out.extend(s[i:j + 1])
    if mask_from is not None:
        _mask_quoted_ops(out, mask_from)
    return j + 1

def _copy_dquote(s, i, out, mask_from=None, join_lines=False):
    # An escaped DQ, backslash, $ or backtick is copied as a pair. join_lines: a backslash-newline
    # is a continuation inside double quotes too, and bash strips both chars.
    n = len(s)
    while i < n:
        c = s[i]
        if join_lines and c == "\\" and i + 1 < n and s[i + 1] == "\n":
            i += 2
            continue
        if c == "\\" and i + 1 < n and s[i + 1] in (DQ, "\\", "$", "`"):
            out.append(c); out.append(s[i + 1])
            i += 2
            continue
        out.append(c)
        i += 1
        if c == DQ:
            if mask_from is not None:
                _mask_quoted_ops(out, mask_from)
            return i
    return n

def _newlines_to_seps(s):
    out = []
    # An escaped separator ("\ ", "\;", "\|", ...) is still a LITERAL character
    # in bash, not a real word break, so a "#" right after it is mid-word, not
    # a comment start -- out[-1] alone can't tell the two apart (both leave the
    # same separator byte in out). This tracks whether the last APPENDED char
    # came from an escaped pair, so the "#" boundary check can discount it.
    last_escaped = False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == SQ:
            out.append(c)
            i = _copy_squote(s, i + 1, out, len(out))
            last_escaped = False
        elif c == DQ:
            out.append(c)
            i = _copy_dquote(s, i + 1, out, len(out), join_lines=True)
            last_escaped = False
        elif c == "\\" and i + 1 < n and s[i + 1] == "\n":
            # real line continuation: both chars removed, nothing appended
            i += 2
        elif c == "\\" and i + 1 < n and s[i + 1] in ";&|()" and not last_escaped and (not out or out[-1].isspace()) and _escaped_op_word_end(s, i) > 0:
            # GH #310: a word made only of escaped operators (\; \&\& \|) is one literal argument
            out.append(HASH_LIT)
            i = _escaped_op_word_end(s, i)
            last_escaped = False
        elif c == "\\" and i + 1 < n:
            # any other escaped pair is consumed together so the escaped char
            # is never re-examined as a hash/quote marker
            out.append(c); out.append(s[i + 1])
            i += 2
            last_escaped = True
        elif c == "#" and not last_escaped and (not out or out[-1] in _REDIRECT_TARGET_STOP):
            out.append(c)
            i = _copy_comment(s, i + 1, out, "\n; ")
            last_escaped = False
        elif c == "#":
            out.append(HASH_LIT); i += 1
            last_escaped = False
        elif c == "\n":
            out.extend("\n; ")
            i += 1
            last_escaped = False
        else:
            out.append(c)
            i += 1
            last_escaped = False
    return "".join(out)

# Command-substitution placeholder pass. A backtick/$(...)/${...}/<(...)/>(...)
# span vanishes in real bash once its output splices in ("gi`true`t" IS "git"),
# but shlex keeps the punctuation literal, so a spliced argv0 evades exact-match
# dispatch. Resolving the substitution would mean running a subshell, so instead
# the span is blanked to one placeholder byte (PH): PH is a shlex wordchar so it
# fuses into the surrounding text as ONE token, and any argv0/subcommand token
# still containing PH is duplicate-classified across every KNOWN_DANGEROUS /
# KNOWN_GIT_SUBS candidate downstream.
# Closer-search depth-counts same-type brackets so nested spans ("$(echo
# $(date))", "$(f() { :; }; f)") resolve in one pass; the fixed-point loop stays
# as defense-in-depth. Out of scope: a bracket hidden behind a quote/escape
# boundary INSIDE the span (quotes tracked at top level only).
# Each downstream flag comparison strips PH itself (full .replace, not a
# leading-only strip: a mid-flag PH like --for<PH>ce is an exact-match bypass).
# Blanking must not DISCARD the body ("$ (git push --force)" is a real deny), so
# every backtick/$(...)/<(...)/>(...) body is re-appended as its own statement;
# a ${...} body is scanned for those nested spans, and a bash 5.3 funsub body
# (`${ cmd; }`) is appended as a command (GH #693). Single-quoted
# spans are never blanked; double-quoted $(...) IS live in bash -- telling them
# apart needs the real quote-state scan below, not a regex. A span inside a "#"
# comment passes through unchanged. <(...)/>(...) (GH #181) is never a real
# "<"/">" redirect -- a redirect target can't start with an unescaped "(" -- so
# blanking it here, before _blank_redirections runs, also stops that "<"/">"
# from being misread as a redirect operator downstream.
PH = "\x01"
# shlex.shlex's own `commenters` (never overridden, stays its default "#") skips
# to the next real "\n" the moment it sees an unquoted "#" ANYWHERE in a token,
# mid-word or not -- it has no word-position awareness, so a literal "foo#bar"
# fed to it unchanged still loses everything from "#" onward, regardless of the
# in_comment tracking below (that tracking only keeps quote-state correct while
# copying comment text through -- see "A span inside a "#" comment passes
# through unchanged" above -- it does not change what shlex itself treats as a
# comment start). A mid-word "#" is swapped for this placeholder before shlex
# ever sees it (a genuine word-boundary "#" is left alone, so shlex's own
# comment-stripping still runs for a real comment); HASH_LIT is added to
# lex.wordchars at both call sites. No downstream restore to "#" is needed: no
# dangerous argv0/flag/subcommand this file matches on contains "#", so a
# placeholder byte counts as one nonflag token exactly like a real "#" would.
# The one exception is the gh api merge-endpoint check, which matches "#" inside
# a word and restores it there (GH #621).
HASH_LIT = "\x02"
# A process-substitution span ("<(cmd)"/">(cmd)", GH #181) blanks to ITS OWN
# placeholder, never bare PH: unlike "$(...)"/backtick, whose expanded value
# IS attacker-controlled to be an arbitrary string (so PH must be fully
# .replace()d back out before any exact flag/subcommand match, everywhere PH
# already is), a process substitution ALWAYS expands to a bash-synthesized
# "/dev/fd/<n>" path -- it can never literally become "-f"/"--force"/"rm"/etc,
# so PSUB never needs that same defensive stripping. The one place PSUB DOES
# matter: a PURE PSUB token (`git checkout main <(true)`) is a real nonflag
# argument to checkout, but not a real worktree pathspec checkout could
# overwrite (a "/dev/fd/<n>" target), so it is excluded from checkout's
# nonflag-arg count (see the "_co_nonflag" line) -- caught by an adversarial
# pass as an over-deny regression on the naive "any extra nonflag arg denies"
# version of this fix.
PSUB = "\x03"
# GH #586: find's `{}` and `\;` are plain words in bash (a `{` opens a group only when a blank follows
# it, and an escaped `;` is never a separator), but the tokenizer cut the statement at each, so find's
# words after the first `{}` (`-exec echo {} \; -delete`) landed in windows no find rule read. Either
# one, standing alone as a word, is swapped for this placeholder (a word character, one nonflag token,
# no dispatch matches it).
WORD_LIT = "\x04"
# Work budget for the depth-counting closer-search, charged per character
# walked and shared across one _scan_once call: without it, a flood of unclosed
# "$(" starts is O(n^2) (65s on a 100,000-char payload under the length cap).
# Exhaustion leaves the span un-blanked -- exactly the bypass shape -- so it is
# recorded here (mutated, not rebound) and denied once after tokenization,
# never reset across the primary and fallback calls. GH #702/#713: it can hold a reason string
# (_PARAM_END_DIFFERS, _SUBST_END_DIFFERS) instead of True (truthy, so the save/restore and body cache carry
# it unchanged), and _deny_if_depth_blown prints that reason.
_DEPTH_BUDGET_BLOWN = [False]
_DEPTH_SCAN_BUDGET = 2_000_000
# GH #713: the work of the second closers that check _close_bracket/_close_psub (_close_param), charged
# apart so the check does not halve the budget nested spans get; reset with each top-level scan's budget.
_CHECK_WORK = [0]
def _close_bracket(s, j, opener, closer, depth_work_used, comments=False):
    # The "$(...)" / "${...}" closer search: from s[j] (just past the opener), count same-type
    # brackets until the matching closer, charging one budget unit per char. Returns the index just
    # past the closer, or None when there is none (end of text, or the budget ran out, which also
    # sets _DEPTH_BUDGET_BLOWN). Quotes inside the span are not tracked (GH #184).
    # GH #713: `comments` (a $(...) body) skips a word-start "#" to the newline, as bash does, so a
    # commented ")" is no closer; read quote-blind like the count, so a quoted " #" only moves the end
    # later (more text read as the body), never earlier. A "#" right after an escaped char is mid-word, as
    # in _close_psub/_close_param/_scan_once (`\ #`), or the skip hides a ")" bash closes on.
    n, depth, start, esc_end = len(s), 1, j, -1
    while j < n and depth and depth_work_used[0] <= _DEPTH_SCAN_BUDGET:
        depth_work_used[0] += 1
        if s[j] == opener:
            depth += 1
        elif s[j] == closer:
            depth -= 1
        elif s[j] == "\\" and j != esc_end - 1:
            esc_end = j + 2
        elif comments and s[j] == "#" and j != esc_end and (j == start or s[j - 1] in _REDIRECT_TARGET_STOP):
            k = s.find("\n", j)
            k = n if k == -1 else k
            depth_work_used[0] += k - j
            j = k
            continue
        j += 1
    if depth and depth_work_used[0] > _DEPTH_SCAN_BUDGET:
        _DEPTH_BUDGET_BLOWN[0] = True
    return None if depth else j

def _close_psub(s, j, depth_work_used, opener="(", closer=")"):
    # The "<(...)" / ">(...)" closer search, same contract as _close_bracket but quote-aware, unlike
    # the "$(...)"/"${...}" one: a ")" inside a quoted string in the body
    # ("<(echo \")\"; rm -rf x)") is not a real closer, and the
    # naive count-every-paren approach those siblings use closes
    # the span early on it, leaving the real dangerous tail as
    # unblanked literal text (a real regression, caught by an
    # adversarial pass; the identical gap in "$(...)" itself is
    # pre-existing and unrelated -- filed as GH #184, not fixed
    # here). Each step (one char, or an escaped pair) charges one budget unit.
    # GH #693: opener "{" finds a funsub's closer; a $(...)/backtick in it may hold a "}" or a quote, so
    # it is skipped whole (an unclosed one leaves the funsub unclosed).
    n, depth = len(s), 1
    tsq = tdq = False
    start, esc_end = j, -1
    while j < n and depth and depth_work_used[0] <= _DEPTH_SCAN_BUDGET:
        depth_work_used[0] += 1
        tc = s[j]
        if tsq:
            if tc == SQ:
                tsq = False
            j += 1
            continue
        if opener == "{" and tc == "`":
            k = s.find("`", j + 1)
            if k == -1:
                return None
            depth_work_used[0] += k - j  # the skipped span is charged per char, like every other step
            j = k + 1
            continue
        if opener == "{" and tc == "$" and s[j + 1:j + 2] == "(":
            j = _close_psub(s, j + 2, depth_work_used)
            if j is None:
                return None
            continue
        if tdq:
            if tc == "\\" and j + 1 < n and s[j + 1] in (DQ, "\\", "$", "`"):
                j += 2
                continue
            if tc == DQ:
                tdq = False
            j += 1
            continue
        if tc == SQ:
            tsq = True; j += 1; continue
        if tc == DQ:
            tdq = True; j += 1; continue
        if tc == "\\" and j + 1 < n:
            j += 2
            esc_end = j
            continue
        # GH #702: a word-start "#" opens a comment bash skips to the newline (same test as _scan_once)
        if tc == "#" and j != esc_end and (j == start or s[j - 1] in _REDIRECT_TARGET_STOP):
            k = s.find("\n", j)
            if k == -1:
                return None
            depth_work_used[0] += k - j
            j = k
            continue
        if tc == opener:
            depth += 1
        elif tc == closer:
            depth -= 1
        j += 1
    if depth and depth_work_used[0] > _DEPTH_SCAN_BUDGET:
        _DEPTH_BUDGET_BLOWN[0] = True
    return None if depth else j

_PARAM_END_DIFFERS = "could not safely tokenize command (a ${...} word ends at a different place for bash than for the gate) - confirm with user first"
_SUBST_END_DIFFERS = "could not safely tokenize command (a ${ ...; } substitution ends at a different place for bash than for the gate) - confirm with user first"
def _at_command_word(s, j, start, esc_end):
    # GH #713: s[j] is in command position in a body that starts at `start`: after a separator, "(", ")",
    # "{", "!", or a reserved word a command follows; an escaped character before it is a word character
    k = j - 1
    while k >= start and s[k] in " \t":
        if k == esc_end - 1:
            return False
        k -= 1
    if k < start:
        return True
    if k == esc_end - 1:
        return False
    return s[k] in ";&|\n(){!" or re.search(r"(?:^|[\s;&|()])(?:then|do|else|if|elif|while|until|time)$",
                                            s[max(start, k - 6):k + 1]) is not None

def _close_param(s, j, depth_work_used, closer="}", _depth=0):
    # GH #702: the end of a ${...} word as bash 5.3 finds it, kept apart from _close_bracket/_close_psub so
    # a wrong count in one does not repeat in the other: the first "}" outside quotes, escapes and nested
    # $(...)/backtick/${...}/$'...'; a bare "{" is not counted. A command body (closer ")" for $(...), "f"
    # for a funsub ending in "}") also skips a word-start "#" comment; ")" counts parens. GH #713: "f" ends
    # at a "}" in command position only, and a "{ " group there nests one. Index past the closer, or None
    # (unclosed, budget, or nesting past 50).
    if _depth >= 50:
        return None
    n, parens, dq, start, esc_end = len(s), 1, False, j, -1
    while j < n and depth_work_used[0] <= _DEPTH_SCAN_BUDGET:
        depth_work_used[0] += 1
        c = s[j]
        if c == "\\":
            j += 2
            esc_end = j
            continue
        if c == "$" and s[j + 1:j + 2] == "{" and s[j + 2:j + 3] in (" ", "\t", "\n", "|"):
            j = _close_param(s, j + 2, depth_work_used, "f", _depth + 1)
            if j is None:
                return None
            continue
        if c == "`":
            k = j + 1
            while k < n and s[k] != "`":
                k += 2 if s[k] == "\\" else 1
            if k >= n:
                return None
            depth_work_used[0] += k - j
            j = k + 1
            continue
        if c == "$" and s[j + 1:j + 2] in ("(", "{"):
            j = _close_param(s, j + 2, depth_work_used, ")" if s[j + 1] == "(" else "}", _depth + 1)
            if j is None:
                return None
            continue
        if dq:
            dq = c != DQ
            j += 1
            continue
        if c == DQ:
            dq = True
        elif c == SQ or (c == "$" and s[j + 1:j + 2] == SQ):
            j += c == "$"
            k = j + 1
            while k < n and s[k] != SQ:
                k += 2 if c == "$" and s[k] == "\\" else 1
            if k >= n:
                return None
            depth_work_used[0] += k - j
            j = k
        elif closer == "}" and c == "}":
            return j + 1
        elif closer == "f" and c in "{}" and _at_command_word(s, j, start, esc_end):
            if c == "}":
                parens -= 1
                if not parens:
                    return j + 1
            elif s[j + 1:j + 2] in (" ", "\t", "\n"):
                parens += 1
        elif closer != "}" and c == "#" and j != esc_end and (j == start or s[j - 1] in _REDIRECT_TARGET_STOP):
            k = s.find("\n", j)
            if k == -1:
                return None
            depth_work_used[0] += k - j
            j = k
        elif closer == ")" and c == "(":
            parens += 1
        elif closer == ")" and c == ")":
            parens -= 1
            if not parens:
                return j + 1
        j += 1
    if depth_work_used[0] > _DEPTH_SCAN_BUDGET:
        _DEPTH_BUDGET_BLOWN[0] = True
    return None

def _substitution_at(s, i, in_dquote, bodies, depth_work_used, _depth, in_param):
    # The substitution that starts at s[i] (a backtick, "$(", "${", or an unquoted "<(" / ">("):
    # (placeholder, index just past it), its command body appended to `bodies`. None when s[i]
    # starts none, or its closer is missing.
    c, nxt = s[i], s[i + 1:i + 2]
    if c == "`":
        j = s.find("`", i + 1)
        if j == -1:
            return None
        bodies.append(s[i + 1:j])
        return PH, j + 1
    if c == "$" and nxt == "(":
        j = _close_bracket(s, i + 2, "(", ")", depth_work_used, comments=True)
        if j is None:
            return None
        # GH #713: the prepass leaves newlines inside "..." alone, but in a $(...) body they separate commands.
        # GH #726: a ${...} word is read quote-blind, so its "..." is unseen there: split in every word.
        bodies.append(_newlines_to_seps(s[i + 2:j - 1]) if in_dquote or in_param else s[i + 2:j - 1])
        return PH, j
    if c == "$" and nxt == "{":
        # A bash 5.3 funsub/valsub (`${ cmd; }`, `${| cmd; }`) is a command, so a quoted "}" in it
        # (`${ echo 'a}'; V; }`) is no closer: find it quote-aware, as for <(...).
        funsub = s[i + 2:i + 3] in (" ", "\t", "\n", "|")
        if funsub:
            j = _close_psub(s, i + 2, depth_work_used, "{", "}")
            # GH #713: bash ends it at a "}" in command position, not at a "}" argument (`"${ echo }; V; }"`)
            if not _DEPTH_BUDGET_BLOWN[0] and _close_param(s, i + 2, _CHECK_WORK, "f") != j:
                _DEPTH_BUDGET_BLOWN[0] = _SUBST_END_DIFFERS
        else:
            j = _close_bracket(s, i + 2, "{", "}", depth_work_used)
            p = _close_param(s, i + 2, _CHECK_WORK)
            # A "}" in a plain "..." ends _close_bracket early (`${y:-"a}b"}`); the quote-crossing fallback
            # after _tokens handles that, so only a body with no $, backtick, ' or \ is let through
            if not _DEPTH_BUDGET_BLOWN[0] and p != j and not (
                    j is not None and p is not None and j < p and not re.search(r"[$`'\\]", s[i + 2:p])):
                _DEPTH_BUDGET_BLOWN[0] = _PARAM_END_DIFFERS
        if j is None:
            # No closer: bash would refuse the text, but GH #233's "}"-masking can eat a real one
            # (`"${x:-"'$(V)'"}"`), so the rest is read as the word, quote-blind, charged to the budget.
            depth_work_used[0] += len(s) - i
            if depth_work_used[0] > _DEPTH_SCAN_BUDGET or _depth >= 50:
                _DEPTH_BUDGET_BLOWN[0] = True
            else:
                _scan_once(s[i + 2:], bodies, depth_work_used, _depth + 1, in_param=True)
            return None
        # GH #693: the word inside ${...} (default, pattern, subscript, offset) still expands, so a
        # $(...)/backtick/<(...) in it runs: scan the body as the <(...) branch does, quote-blind (bash's
        # quote rules there vary by operator; fail closed), and keep only the nested bodies. A funsub
        # body is scanned with normal quoting and appended blanked, as the <(...) body is (a backtick
        # nested in an appended body is not read again downstream, and a raw one would repeat its nested
        # bodies once per level).
        body = s[i + 2:j - 1]
        if funsub:
            body = body[1:] if body[0] == "|" else body
        if _depth >= 50:
            _DEPTH_BUDGET_BLOWN[0] = True
        elif not funsub:
            _scan_once(body, bodies, depth_work_used, _depth + 1, in_param=True)
        else:
            body = _scan_once(body, bodies, depth_work_used, _depth + 1)
            try:
                shlex.split(body)
            except ValueError:
                # an unbalanced quote here would pair with one left in the main text and hide its tail; a
                # reason already set (a nested ${...} word that closed in the wrong place) is the cause, kept
                _DEPTH_BUDGET_BLOWN[0] = _DEPTH_BUDGET_BLOWN[0] or True
            bodies.append(body)
        return PH, j
    if c in ("<", ">") and not in_dquote and nxt == "(":
        # Process substitution (GH #181): "<(cmd)"/">(cmd)" is a WORD,
        # never a real redirect (a real "<"/">" redirect target can't
        # start with "(" unescaped), so it must be blanked here, the
        # same as "$(...)", BEFORE _blank_redirections ever sees the
        # "<"/">" -- otherwise that bare "<"/">" is misread as an input/
        # output redirect operator, and the body's own closing ")"
        # (never a real word boundary here) reaches the "#"-boundary
        # check as a bare character.
        # "not in_dquote": unlike "$(...)"/backtick (live inside double
        # quotes in real bash, correctly recognized either way by the
        # sibling branches above), "<(...)"/">(...)" is INERT text
        # inside double quotes -- "echo \"<(rm -rf x)\"" must stay a
        # harmless literal string, not get its quoted body extracted
        # and re-scanned as a real command (an adversarial pass caught
        # this as an over-deny regression).
        j = _close_psub(s, i + 2, depth_work_used)
        if j is None:
            return None
        # The extracted body is spliced back as its own top-level
        # statement ("\n; " + body) only once, after the whole
        # _blank_substitutions call returns -- never re-examined by the scan
        # loop again. A DIFFERENT-type substitution nested inside it
        # (a backtick inside "<(...)") would otherwise survive
        # unblanked all the way to shlex, still glued to its
        # neighbor characters and evading exact-match dispatch
        # (an adversarial pass caught this live: "<(echo `rm -rf
        # x`)" reached shlex as "`rm", never matching "rm").
        # Recursively re-scanning it here (the "${...}" branch
        # above does the same since GH #693; "$(...)" shares the
        # gap, filed as GH #185) closes that while a shared
        # depth_work_used bounds the total work across every
        # recursion level to one budget; _depth caps the
        # recursion itself, since a budget check alone doesn't
        # stop Python's own RecursionError on a deep chain of
        # cheap, properly-closed spans.
        body = s[i + 2:j - 1]
        if _depth < 50:
            body = _scan_once(body, bodies, depth_work_used, _depth + 1)
        else:
            _DEPTH_BUDGET_BLOWN[0] = True
        bodies.append(body)
        return PSUB, j
    return None

# One left-to-right pass with real quote/comment state; collects
# backtick/$(...) bodies, and those nested in ${...} (GH #693), into the shared `bodies` list.
# `depth_work_used`/`_depth`: the <(...)/>(...) branch (GH #181) and the ${...} branch
# pass these, to recursively re-scan their own extracted body for a
# nested different-type substitution (a backtick nested inside "<(...)"
# was found live/unscanned by an adversarial pass -- see the GH #181
# comment on that branch); `in_param` reads a ${...} word quote-blind. The
# top-level fixed-point loop below never passes them, so its own budget
# and depth are unchanged from before. Sharing one `depth_work_used`
# list across the whole recursion (never a fresh one per call) keeps the
# total work bounded by one _DEPTH_SCAN_BUDGET regardless of nesting
# depth (plus one more for the check closers, _CHECK_WORK); `_depth` caps the recursion itself, since a budget check alone
# does not stop Python's own RecursionError on ~1000 properly-closed,
# budget-cheap nested spans.
def _scan_once(s, bodies, depth_work_used=None, _depth=0, in_param=False):
    if depth_work_used is None:
        depth_work_used = [0]
        _CHECK_WORK[0] = 0
    out = []
    in_dquote = False
    # See _newlines_to_seps's own comment: an escaped separator is still a
    # literal char in bash, not a real word break, so a "#" right after it
    # is mid-word -- out[-1] alone can't tell the two apart.
    last_escaped = False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if in_dquote:
            if c == "\\" and i + 1 < n and s[i + 1] in (DQ, "\\", "$", "`"):
                out.append(c); out.append(s[i + 1])
                last_escaped = False
                i += 2
                continue
            if c == DQ:
                out.append(c)
                in_dquote = False
                last_escaped = False
                i += 1
                continue
            # else: fall through -- substitutions ARE live inside double quotes
        else:
            # in_param (a ${...} word, GH #693): quote- and comment-blind, so every $(/backtick/<( is live.
            if c == SQ and not in_param:
                out.append(c)
                i = _copy_squote(s, i + 1, out)
                last_escaped = False
                continue
            if c == DQ and not in_param:
                in_dquote = True
                out.append(c); i += 1
                last_escaped = False
                continue
            if c == "\\" and i + 1 < n:
                out.append(c); out.append(s[i + 1])
                i += 2
                last_escaped = True
                continue
            if c == "#" and not in_param and not last_escaped and (not out or out[-1] in _REDIRECT_TARGET_STOP):
                out.append(c)
                i = _copy_comment(s, i + 1, out, "\n")
                last_escaped = False
                continue
            if c == "#":
                out.append(HASH_LIT); i += 1
                last_escaped = False
                continue
        if c in "`$<>":
            sub = _substitution_at(s, i, in_dquote, bodies, depth_work_used, _depth, in_param)
            if sub:
                out.append(sub[0])
                i = sub[1]
                last_escaped = False
                continue
        out.append(c)
        i += 1
        last_escaped = False
    return "".join(out)

def _blank_substitutions(s):
    bodies = []
    for _ in range(5):
        new = _scan_once(s, bodies)
        if new == s:
            break
        s = new
    if bodies:
        # A real "\n" before each body ends any open "#" comment (a plain " ; "
        # join let a trailing comment swallow every appended body).
        s = s + "\n; " + "\n; ".join(bodies)
    return s

# A real shell redirection ([n]<word / [n]>[>]word / [n]<&word / [n]>&word /
# [n]<<<word / &>word / &>>word) is consumed entirely by bash before the
# target program's own argv is built -- it never reaches git, so a downstream
# nonflag-arg count or exact-token check (e.g. checkout's "1 nonflag = branch
# switch, 2+ = tree-ish+path") must not see it. A prior attempt fixed this by
# stripping matching tokens AFTER shlex(posix=True) tokenized the command --
# rejected (2026-09-29, found by an adversarial Codex pass, see
# security-gate-token-strip-needs-quote-state memory): posix=True dequotes, so
# a LITERAL quoted ">" and a real unquoted > redirect become the identical
# token string, and stripping "a bare digit immediately before an operator
# token" can't tell a real fd-prefix ("2>&1", no space) from a real positional
# arg that happens to be a digit followed by a separately-spaced redirect
# ("checkout HEAD 2 >out" -- shlex has already discarded whether that space
# existed). Both are only resolvable from the RAW string, where quoting and
# spacing are both still intact -- so this runs BEFORE shlex, on the raw
# command text, with real quote/comment state tracked char-by-char exactly
# like _newlines_to_seps above (same escape-pair and quote-toggle rules), never
# treating a quoted or backslash-escaped character as a real operator. Matched
# spans are DELETED outright, not blanked to PH: PH would make a token vanish
# from the "compacted" window copy below but still count in the RAW copy (PH
# is a wordchar, so it's still one non-flag token there) -- and "a deny in
# either copy wins" means the raw copy's inflated nonflag count would still
# false-deny, exactly the bug this exists to fix. A redirect target is never
# itself a command to re-scan for danger (unlike a $(...) body), so nothing
# needs to survive at that position the way a substitution's body does.
# Runs AFTER _blank_substitutions so a redirect character inside a $(...) body
# that gets re-appended as its own statement is still correctly re-scanned
# (it's real command text by then), and one already blanked to PH is not
# double-processed (PH itself never matches the redirect-operator regex).
# "#" is NOT in this set: bash only treats "#" as a comment-starter at the
# START of a word, not glued mid-word ("out#suffix" is one literal filename) --
# handled as a special case in the target loop below (round 2, found by an
# adversarial Codex pass: `git checkout HEAD >out#suffix <realfile>` let the
# target-consumption stop at "#", silently dropping <realfile> from the scan
# entirely; that exact payload correctly denies on the unmodified gate).
# "{"/"}" are ALSO not in this set, for the same reason, found the same way
# (round 3): unlike "(" and ")" -- real, always-special shell operators, a bare
# unquoted "{"/"}" mid-word is just a literal character in bash (verified live:
# `bash -n -c 'echo out{suffix'` is a syntax error for "(" but NOT for "{" --
# only paired, comma/range-shaped brace expansion is special, and only at a
# word boundary). `git checkout HEAD >out{suffix <realfile>` bypassed the same
# way the "#" case did before this line excluded them too.
# GH #188: bash 4+'s named-fd form "{var}>file" is a redirect too. Its "{var}"
# prefix used to survive as text: the outer tokenizer split it into "{" "var"
# "}" (window breaks), cutting `checkout HEAD {fd}>/dev/null <path>` off before
# <path> (fail-open), and the bash -c/eval tokenizer (whitespace_split) kept
# "{fd}" as one nonflag arg (over-deny on a plain branch switch). Only matched
# at a word start (checked at the call site): "x{fd}>f" is the literal word
# "x{fd}" followed by a plain ">f" redirect. Like an fd number, "{var}" never
# prefixes "&>"/"&>>" ("{fd}&>x" is the word "{fd}" plus a redirect). ">|"
# (noclobber) and "<>" are operators too: without ">|", "{fd}>|x <path>" left
# "|x <path>" as a pipe that cut the window before <path> (#208 validator).
_REDIRECT_OP_RE = re.compile(
    r"\{[A-Za-z_][A-Za-z0-9_]*\}(?:>>|<<<|<<|>&|<&|>\||<>|>|<)"
    r"|\d{0,2}(?:>>|<<<|<<|>&|<&|&>>|&>|>\||<>|>|<)")
# GH #219: zsh alone takes "{var}&>f" as a named-fd redirect (bash reads the word "{var}" plus "&>f").
_REDIRECT_OP_ZSH_RE = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\}(?:&>>|&>)|" + _REDIRECT_OP_RE.pattern)
_REDIRECT_TARGET_STOP = set(" \t\n;|&()")
def _past_quoted(s, k):
    # s[k] opens a quote: the index just past its close, or len(s). Inside double quotes an escaped
    # DQ, backslash, $ or backtick is skipped as a pair.
    n = len(s)
    if s[k] == SQ:
        j = s.find(SQ, k + 1)
        return n if j < 0 else j + 1
    k += 1
    while k < n:
        if s[k] == "\\" and k + 1 < n and s[k + 1] in (DQ, "\\", "$", "`"):
            k += 2
        elif s[k] == DQ:
            return k + 1
        else:
            k += 1
    return n

def _redirect_target_end(s, j):
    # The index just past the target word of a redirect operator that ends at s[j]: blanks first,
    # then the word, itself quote/escape-aware (a quoted or spaced redirect target, "> \"my file\"",
    # is one word).
    n = len(s)
    while j < n and s[j] in " \t":
        j += 1
    k = j
    while k < n:
        tc = s[k]
        if tc == SQ or tc == DQ:
            k = _past_quoted(s, k)
        elif tc == "\\" and k + 1 < n:
            k += 2
        elif tc == "#" and k == j:
            # "#" as the very first target char IS a real word-start,
            # i.e. a genuine comment ("> #comment") -- leave it for the
            # outer dispatcher's own "#" branch to enter comment state
            # correctly, rather than swallowing it here.
            break
        elif tc in _REDIRECT_TARGET_STOP:
            break
        else:
            k += 1
    return k

_WORD_END_RE = re.compile(r"\d*[<>]|[ \t\n;&|)]|$")
def _alone(s, i, k):
    # True when s[i:i + k] is a whole word: a blank (or the start) before it, a blank, a separator, a
    # redirect (`\;>/dev/null`, `{}2>x`) or the end after it.
    return (i == 0 or s[i - 1] in " \t\n") and _WORD_END_RE.match(s, i + k) is not None

def _blank_redirections(s, named_fd=True):
    # named_fd: True = bash 4+/ksh93 (consume "{var}>f"), False = macOS /bin/sh, bash 3.2, dash (the
    # literal word "{var}" plus a plain redirect), "zsh" = True plus "{var}&>f" (GH #219).
    # Callers check every reading; any deny wins.
    op_re = _REDIRECT_OP_ZSH_RE if named_fd == "zsh" else _REDIRECT_OP_RE
    out = []
    # See _newlines_to_seps's own comment: an escaped separator is still a
    # literal char in bash, not a real word break, so a "#" right after it
    # is mid-word -- out[-1] alone can't tell the two apart.
    last_escaped = False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == SQ:
            out.append(c)
            i = _copy_squote(s, i + 1, out)
            last_escaped = False
            continue
        if c == DQ:
            out.append(c)
            i = _copy_dquote(s, i + 1, out)
            last_escaped = False
            continue
        if c == "\\" and s[i + 1:i + 2] == ";" and _alone(s, i, 2):
            out.append(WORD_LIT)  # GH #586: find's `\;`
            i += 2
            last_escaped = False
            continue
        if c == "{" and s[i + 1:i + 2] == "}" and _alone(s, i, 2):
            out.append(WORD_LIT)  # GH #586: find's / xargs's `{}`
            i += 2
            last_escaped = False
            continue
        if c == "\\" and i + 1 < n:
            # an escaped char (including an escaped ">"/"<") is never a real
            # operator -- consumed together so it is not re-examined below.
            out.append(c); out.append(s[i + 1])
            i += 2
            last_escaped = True
            continue
        if c == "#" and not last_escaped and (not out or out[-1] in _REDIRECT_TARGET_STOP):
            out.append(c)
            i = _copy_comment(s, i + 1, out, "\n")
            last_escaped = False
            continue
        if c == "#":
            out.append(HASH_LIT); i += 1
            last_escaped = False
            continue
        m = op_re.match(s, i)
        # mid-word "{": literal text, not a named fd (GH #188). After an
        # escaped char ("x\ {fd}>f") it is still read as a redirect: keeping
        # "{" as text lets the outer tokenizer break the window at "{".
        if m and c == "{" and (not named_fd or (out and out[-1] not in _REDIRECT_TARGET_STOP)):
            m = None
        if m:
            # Leave a space where the redirect was: deleting it outright can
            # glue the punctuation on either side into one shlex token (")"
            # + ";" -> ");", not in OPERATORS), hiding the window break before
            # a dangerous tail (found by the GH #188 differential fuzz).
            out.append(" ")
            i = _redirect_target_end(s, m.end())
            last_escaped = False
            continue
        out.append(c)
        i += 1
        last_escaped = False
    return "".join(out)

def _blanked(c, named_fd=True):
    # The text every tokenizer below reads: ANSI-C quotes decoded, newlines turned into separators,
    # substitutions and redirections blanked. Recomputed on every call: each _blank_substitutions run
    # charges a fresh depth-scan budget and may set _DEPTH_BUDGET_BLOWN.
    return _blank_redirections(_blank_substitutions(_newlines_to_seps(_normalize_ansi_c_quotes(c))), named_fd)

# GH #375: shlex splits one shell word at each character outside its wordchars ($, :, @, a Thai
# letter): `$PWD` is "$", "PWD". A token that shlex cut from the one before it, with no blank
# between them, comes back as _Glued (an equal str, so every other check reads it unchanged).
class _Glued(str):
    __slots__ = ()

def _tokens(src, extra_wordchars="", whitespace_split=False):
    # shlex tokens of a _blanked() text; the placeholders are word characters. Raises ValueError.
    lex = shlex.shlex(src, posix=True, punctuation_chars=True)
    lex.wordchars += PH + HASH_LIT + PSUB + WORD_LIT + extra_wordchars
    if whitespace_split:
        lex.whitespace_split = True
        return list(lex)
    out, glued = [], False
    while True:
        tok = lex.get_token()
        if tok is None:
            return out
        out.append(_Glued(tok) if glued else tok)
        # A token cut at a non-word character pushes that character back; a one-character token
        # ("$") ends without reading on. Either way the next token is glued unless a blank comes first.
        back = getattr(lex, "_pushback_chars", ())
        end = lex.instream.tell() - len(back)
        glued = bool(back) or (end < len(src) and src[end - 1] not in lex.whitespace
                               and src[end] not in lex.whitespace)

# shlex.split() only recognizes ;/&&/||/|/& as separators when whitespace
# surrounds them ("echo hi;rm -rf x" glued "hi;rm"); punctuation_chars=True
# splits them out as their own tokens while respecting quotes. ( ) { } get the
# same treatment so "(rm -rf x)" / "{ rm -rf x; }" do not leave "(" as argv0.
OPERATORS = {";", "&&", "||", "|", "&", "(", ")", "{", "}"}

# The only whole-command shape in which `git branch -D` is allowed (see the branch rule).
_BRANCH_D_PLAIN_RE = re.compile(
    r"git(?:[ \t]+-C[ \t]+[\w./~-]+)?[ \t]+branch"
    # "@" inside a name is literal to the shell; "{" stays out, so "x@{1}" never matches. "#" stays out
    # too: under zsh extendedglob "ma#in" globs to a "main" entry in the cwd (deep-audit 2026-10-01).
    r"((?:[ \t]+(?:-[dDfrq]+|--(?:delete|force|remotes|quiet)?|\w[\w./+@-]*))+)",
    # ASCII only: a Unicode \w lets "maſter" (U+017F) through, which a
    # case-insensitive filesystem folds onto refs/heads/master (validator round 2).
    re.ASCII)
_OPS_LONGEST_FIRST = sorted(OPERATORS, key=len, reverse=True)

# shlex fuses a run of punctuation into ONE token: ");", "&&(", ")|", ")|&", ";;".
# None of those is in OPERATORS, so the window never split and the next command
# stayed an argument of the previous one. A token made only of operators is cut
# back into them; anything with another character (a redirection) is left alone.
# shlex has already dropped the quotes, so a QUOTED argument of that shape
# (echo ');' rm -rf x) is split too: an over-deny, the safe direction, and the
# same limit a quoted ";" always had here.
def _split_ops(tok):
    if tok in OPERATORS:
        return [tok]
    out, i = [], 0
    while i < len(tok):
        for op in _OPS_LONGEST_FIRST:
            if tok.startswith(op, i):
                out.append(op)
                i += len(op)
                break
        else:
            return [tok]
    return out

def _statements(toks, keep_empty=False):
    # Yield each non-empty run of tokens between OPERATORS (one statement window).
    # _split_ops("") is [], so an empty word ("") drops out unless keep_empty (GH #382).
    cur = []
    for tok in [p for t in toks for p in (_split_ops(t) or ([t] if keep_empty else []))] + [";"]:
        if tok in OPERATORS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(tok)

# GH #382: every walk below reads one token as one shell word (sudo -u, env -u, timeout's duration,
# a NAME=value prefix, a wrapper's dash words, find/xargs/docker slices, argv0 itself), so a value
# shlex split (`sudo -u $U git ...`: "$", "U") shifted the walk onto the variable's name. The same
# walks also lost an empty word: `git -C "" reset` read -C's value as `reset`. A second reading of
# each statement, as the shell's words (each glued run joined, an empty word kept), is checked after
# every token window, by every rule. The token reading stays as it was, so a deny in either wins
# (`git "" reset --hard` and `"" rm -rf x` deny only in the token reading).
def _shell_words(cur):
    out, run = [], []
    for t in cur:
        if run and not isinstance(t, _Glued):
            out.append("".join(run))  # plain str: a word window never re-joins
            run = []
        run.append(t)
    if run:
        out.append("".join(run))
    return out

def _readings(toks):
    # (token window, word window or None when it reads the same) per statement of toks.
    for cur in _statements(toks, keep_empty=True):
        tw = [t for t in cur if t != ""]
        ww = _shell_words(cur)
        yield tw, (ww if ww != tw else None)

_WORDS, _WORDS_SEEN = [], set()  # word windows (depth, words) waiting for the token windows to finish
def _queue_words(ww, depth):
    key = tuple(ww)
    if key not in _WORDS_SEEN:
        _WORDS_SEEN.add(key)
        _WORDS.append((depth, ww))

def _drop_ph_tokens(w):
    # w without its bare-placeholder tokens (a substitution that may expand to nothing).
    return [t for t in w if not (t and all(c == PH for c in t))]

if len(cmd) > _CMD_LEN_CAP:
    deny("command too long to safely tokenize (" + str(len(cmd)) + " chars, cap " + str(_CMD_LEN_CAP) + ") - confirm with user first")
# GH #668 round 3: a mark line goes where each kept data body ends, and the tokenizer's own reader runs once:
# a mark not at a statement start sits in a quote or a join, so a quote in the body (or on its opener
# line) pairs with one past the delimiter and would hide the lines between. A command holding the mark
# (a noncharacter) could forge one. Structural, so no rule id and no shadow (repo-gotchas.md, GH #337).
_KEPT_MARK = "﷑"
if _KEPT_BODY_ENDS:
    _at, _marked, _lns = set(_KEPT_BODY_ENDS), [], cmd.split("\n")
    for _k in range(len(_lns) + 1):  # index len(_lns): a body that ends the command
        if _k in _at:
            _marked.append(_KEPT_MARK)
        if _k < len(_lns):
            _marked.append(_lns[_k])
    if _KEPT_MARK in cmd or _newlines_to_seps(_normalize_ansi_c_quotes("\n".join(_marked))).count(
            "\n; " + _KEPT_MARK) < len(_at):
        deny("a heredoc body the gate reads as commands leaves a quote open - confirm with user first")
if _HEREDOC_UNMATCHED[0]:
    deny("a heredoc the gate reads unsure has no closing delimiter it can find - confirm with user first")
# GH #741: the shell runs code the gate cannot read. Enforced (operator, 2026-11-01): the attack review found 0
# regressions and 0 false denies over 139,446 real Bash commands; a safe script that prints safe commands into
# a shell (print("ls") | sh) is denied too, with a way out in the message.
if _INTERP_PIPED_SHELL[0]:
    deny("a python/node heredoc script pipes its output into a shell, which runs commands the gate cannot see - "
         "write the commands out, or save the output to a file and read it first", rule="interp-pipe-shell")

def _sql_stdin_drop(c):
    # SQL a client reads on stdin drops or truncates: a heredoc body it reads (_SQL_HEREDOC_DROP), a
    # here-string on its own stage, or the data a stage upstream of it in its pipeline emits. Text downstream
    # of the client is its output (psql -c '\d' | grep -i 'drop table'), so it is not read.
    # GH #559 review 2: only echo/printf words and a cat here-string count as emitted data; another stage's
    # words (git diff | grep -v 'DROP TABLE' | psql) are arguments, not the SQL that reaches the client.
    if _SQL_HEREDOC_DROP[0]:
        return True
    if not _may_name_client(c) or not _SQL_DROP_RE.search(_dequoted(c)):
        return False
    if "$'" in c:
        c = _normalize_ansi_c_quotes(c)  # GH #697: echo $'DROP TABLE t' | $'psql' reads decoded
    for s, e in _pieces(c):
        segs = [c[s + a:s + b] for a, b in _pieces(c[s:e], pipe=True)]
        k = next((k for k, g in enumerate(segs) if _runs_sql_client(g)), None)
        if k is None:
            continue
        data = []
        for g in segs[:k]:
            a0, rest = _stage_cmd(g)
            if a0 in ("echo", "printf"):
                data.extend(rest)
            elif a0 == "cat" and "<<<" in g:
                data.extend(_words(g.split("<<<", 1)[1]))
        here = segs[k].split("<<<", 1)
        if len(here) > 1:
            data.extend(_words(here[1]))
        # GH #621 review 3: psql -a echoes its input on, so a non-SQL client anywhere downstream reads it too.
        if _sql_drops(" ".join(data), not _NON_SQL_CLIENT_RE.search(_dequoted("|".join(segs[k:])))
                      and not any(_stage_cmd(g)[0] == _OPAQUE_ARGV0 for g in segs[k:])):
            return True
    return _group_piped_sql_drop(c) if "}" in c or ")" in c else False

# GH #621: a { } or ( ) group piped into a client feeds it the output of every command in the group, but the
# split above cuts { echo 'DROP TABLE t'; } | psql at the ; and loses the echo. This second reading walks
# the command once with a stack of open groups (and $( ) substitutions) and, at the first client of a
# pipeline whose upstream holds a group, reads the echo/printf/cat <<< words of every stage upstream of it,
# the group's inner stages included. A stage's own text leaves out its nested groups, so each character is
# read once; the text the clients read is budgeted at four times the command, and an overrun denies.

class _SqlFrame:
    __slots__ = ("kind", "seg", "parts", "pipe", "data_at", "has_group", "group", "blank", "done")
    def __init__(self, kind, seg, pipe):
        self.kind, self.seg, self.parts, self.pipe, self.data_at = kind, seg, [], pipe, pipe
        self.has_group = self.group = self.done = False
        self.blank = True

def _group_piped_sql_drop(c):
    data, seen, n = [], set(), len(c)
    js_any = bool(_NON_SQL_CLIENT_RE.search(_dequoted(c))) or _has_opaque_argv0(c)  # later stages are unread
    budget = [4 * n + 100_000]
    frames = [_SqlFrame(None, 0, 0)]

    def end_stage(f, i, piped):
        f.parts.append(c[f.seg:i])
        text = "".join(f.parts)
        if f.group:
            f.has_group = f.has_group or piped
        else:
            a0, rest = _stage_cmd(text)
            if a0 in _SQL_CLIENTS or a0 == _OPAQUE_ARGV0:
                if f.has_group and not f.done:
                    f.done = True
                    here = text.split("<<<", 1)
                    key = (f.pipe, f.data_at) if len(here) == 1 else None
                    if key not in seen:
                        seen.add(key)
                        sql = " ".join(data[f.pipe:f.data_at] + (list(_words(here[1])) if len(here) > 1 else []))
                        budget[0] -= len(sql)
                        if budget[0] < 0:
                            return "budget"
                        if _sql_drops(sql, not js_any):
                            return True
            elif a0 in ("echo", "printf"):
                data.extend(rest)
            elif a0 == "cat" and "<<<" in text:
                data.extend(_words(text.split("<<<", 1)[1]))
        if not piped:
            f.pipe, f.has_group, f.done = len(data), False, False
        f.parts, f.group, f.blank, f.data_at = [], False, True, len(data)
        return False

    i, q, last, last2 = 0, None, "", ""
    while i < n:
        ch, w, f = c[i], 0, frames[-1]
        if q:
            if ch == "\\" and q == '"':
                i += 1
            elif ch == q:
                q = None
            i += 1
            continue
        if ch == "\\":
            f.blank = False
            i += 2
            last, last2 = ch, last
            continue
        if ch in "'\"":
            q, f.blank = ch, False
        elif ch == "#" and (i == 0 or c[i - 1] in " \t\n;&|()"):
            j = c.find("\n", i)
            i = n if j < 0 else j
            continue
        elif ch == "\n" and (last == "|" or last + last2 == "&&"):
            pass
        elif ch == "(" or (ch == "{" and f.blank and c[i + 1:i + 2] in (" ", "\t", "\n")):
            group = f.blank and c[i - 1:i] not in ("$", "<", ">")
            f.parts.append(c[f.seg:i])
            f.seg, f.blank = n, False  # set again where the group closes
            frames.append(_SqlFrame("(" + ("g" if group else "") if ch == "(" else "{g", i + 1, len(data)))
        elif len(frames) > 1 and ((ch == ")" and f.kind[0] == "(") or (ch == "}" and f.kind == "{g" and f.blank)):
            r = end_stage(f, i, False)
            if r:
                return r
            frames.pop()
            p = frames[-1]
            p.seg, p.blank = i + 1, False
            p.group = p.group or f.kind.endswith("g")
        elif c.startswith(("&&", "||"), i):
            w = 2
        elif ch == "|":
            w = 2 if c[i + 1:i + 2] == "&" else 1
            r = end_stage(f, i, True)
            if r:
                return r
            f.seg, w = i + w, -w
        elif ch in ";\n" or (ch == "&" and c[i - 1:i] not in (">", "<", "|") and c[i + 1:i + 2] != ">"):
            w = 1
        elif ch not in " \t":
            f.blank = False
        if w > 0:
            r = end_stage(f, i, False)
            if r:
                return r
            f.seg = i + w
        if ch not in " \t\n":
            last, last2 = ch, last
        i += abs(w) or 1
    for f in reversed(frames):
        r = end_stage(f, n, False)
        if r:
            return r
    return False

def _decode_quotes(t):
    # GH #664: shlex reads `$'rm -rf b'` as the word `$rm -rf b` and `$"x"` as `$x`. The shell gives the
    # decoded text (ANSI-C escapes resolved; a $"..." locale string is its plain text), so that is what is read.
    # A `$"` is a locale string unless an odd run of backslashes escapes its `$` (`\\$"x"` is `\` then $"x").
    return _normalize_ansi_c_quotes(re.sub(r'(?<![\\$])(\\*)\$(?=")',
                                           lambda m: m.group(0) if len(m.group(1)) % 2 else m.group(1), t),
                                    live_only=True) if "$" in t else t

# GH #801: a python/node stage that runs an inline script (python3 -c, node -e/-p/--eval/--print), so whatever it
# prints is unseen, like a GH #741 heredoc script. Read from the stage's words past every wrapper (_past_run_prefix).
# GH #815: perl -e/-E and ruby -e too. A short cluster is read letter by letter: a letter in `rest` takes the rest of
# the word as its value (perl -Mfeature=say, -I/opt/e; python -mcProfile), so an e or c inside a value is no flag.
_INLINE_SCRIPT_FLAGS = {"python": ("-c",), "node": ("-e", "-p", "--eval", "--print"), "perl": ("-e", "-E"),
                        "ruby": ("-e",)}
_INLINE_VALUE_FLAGS = {"python": ("-W", "-X"),
                       "node": ("-r", "--require", "--import", "--loader", "--experimental-loader", "--input-type", "-C",
                                "--conditions", "--title", "--env-file", "--env-file-if-exists", "--redirect-warnings",
                                "--openssl-config", "--icu-data-dir", "--disable-warning", "--watch-path",
                                "--diagnostic-dir", "--report-dir", "--report-directory", "--report-filename",
                                "--unhandled-rejections", "--dns-result-order", "--cpu-prof-dir", "--heap-prof-dir",
                                "--trace-event-categories", "--trace-event-file-pattern", "--heapsnapshot-signal",
                                "--secure-heap", "--secure-heap-min", "--localstorage-file", "--experimental-config-file"),
                       "perl": ("-I",), "ruby": ("-I", "-r", "-C", "-E", "--encoding", "--external-encoding",
                                                 "--internal-encoding", "--enable", "--disable")}
_INLINE_REST_LETTERS = {"python": "WXmQ", "node": "rC", "perl": "IMmxiFCdD", "ruby": "IrCEFixKWT"}
_INLINE_INTERP_RE = re.compile(r"python[23]?(?:\.\d+)?|node(?:js)?|perl(?:5[\d.]*)?|ruby(?:\d[\d.]*)?")
_INLINE_NAME_RE = re.compile(r"python|node|perl|ruby")
# GH #815: a project runner runs its program in the project's environment: `uv run [opts] python -c ..`. Its value
# options (a word of their own) are skipped; an unknown one leaves its value as the program, which names no python.
_PROJECT_RUNNERS = {
    "uv": ("--with", "--with-editable", "--with-requirements", "--python", "-p", "--project", "--directory", "--package",
           "--extra", "--group", "--only-group", "--no-group", "--env-file", "--index", "--default-index", "--index-url",
           "-i", "--extra-index-url", "--find-links", "-f", "--config-file", "--cache-dir", "--index-strategy",
           "--keyring-provider", "--resolution", "--prerelease", "--exclude-newer", "--link-mode", "--refresh-package",
           "--reinstall-package", "--upgrade-package", "-P", "--no-binary-package", "--no-build-package",
           "--config-setting", "-C", "--color", "--allow-insecure-host", "--python-preference", "--python-platform"),
    "poetry": ("-C", "--directory", "-P", "--project"), "pipenv": (), "pdm": ("-p", "--project", "-r", "--root"),
    "hatch": ("-e", "--env"), "rye": ("--pyproject",), "conda": ("-n", "--name", "-p", "--prefix", "--cwd"),
    "mamba": ("-n", "--name", "-p", "--prefix", "--cwd"), "micromamba": ("-n", "--name", "-p", "--prefix", "--cwd"),
}

def _past_project_runner(w, i):
    # GH #815: the program word past a project runner's `run` and its options (and past any wrapper after them).
    for _ in range(4):
        if i is None or i + 1 >= len(w) or w[i].rsplit("/", 1)[-1] not in _PROJECT_RUNNERS or w[i + 1] != "run":
            return i
        vals = _PROJECT_RUNNERS[w[i].rsplit("/", 1)[-1]]
        i += 2
        while i < len(w) and w[i].startswith("-") and len(w[i]) > 1:
            done = w[i] == "--"
            i += 2 if w[i] in vals else 1
            if done:
                break
        i = _past_run_prefix(w, i) if i < len(w) else None
    return i

def _runs_inline_interp(seg):
    if not _INLINE_NAME_RE.search(seg.translate(_UNQUOTE)):
        return False
    w = _split_words(seg)
    w = _without_out_redirects(w) if w else None
    i = _past_project_runner(w, _past_run_prefix(w)) if w else None
    if i is None or i >= len(w):
        return False
    m = _INLINE_INTERP_RE.fullmatch(w[i].rsplit("/", 1)[-1])
    if not m:
        return False
    kind = next(k for k in _INLINE_SCRIPT_FLAGS if m.group().startswith(k))
    flags, valued, rest = _INLINE_SCRIPT_FLAGS[kind], _INLINE_VALUE_FLAGS[kind], _INLINE_REST_LETTERS[kind]
    letters = {f[1] for f in flags if not f.startswith("--")}
    skip = False
    for t in w[i + 1:]:
        if skip:
            skip = False
            continue
        if t == "--" or not t.startswith("-") or t == "-":
            return False  # a script file or `-`: not an inline script
        if t.partition("=")[0] in flags:
            return True
        if t in valued:
            skip = True  # its value is the next word (python3 -W ignore -c, node -r ts-node/register -e)
            continue
        if t.startswith("--"):
            continue
        # a short cluster holding the script letter (python3 -uc, node -pe, perl -lne), read up to a letter
        # that takes the rest of the word (-Wignore, -Mstrict)
        for ch in t[1:]:
            if ch in letters:
                return True
            if ch in rest:
                break
    return False

def _join_continuations(c):
    # GH #815: a backslash-newline outside quotes is no character to the shell (`| \` then `bash` on the next line
    # is `| bash`). Inside quotes the pair stays, which only changes how a quoted probe string reads.
    return re.sub(r"(?<!\\)((?:\\\\)*)\\\n", r"\1", c) if "\\\n" in c else c

def _group_ends(g):
    # GH #815: (leading closers, opens, core, trailing closers) of a pipe stage in a { } or ( ) group, which _pieces
    # does not model: `{ python3 -c 1; } | bash` splits at the `;` into `{ python3 -c 1` and `} | bash`, and
    # `(python3 -c 1) | bash` keeps `(python3 -c 1)` as one stage. A trailing ) counts only past the stage's own
    # unquoted ( ones, so `$(date)` closes nothing; the core ends at the first one. Index scans: linear.
    t, i, n, lead, opens = g, 0, len(g), 0, 0
    while i < n and (t[i] in " \t\n" or t[i] in "})"):
        lead += t[i] in "})"
        i += 1
    while i < n and ((t[i] == "(" and t[i + 1:i + 2] != "(") or (t[i] == "{" and t[i + 1:i + 2] in (" ", "\t", "\n"))
                     or (opens and t[i] in " \t\n")):
        opens += t[i] in "({"
        i += 1
    t = t[i:]
    mask = _quote_mask(t)
    depth = trail = 0
    cut = len(t)
    for k, ch in enumerate(t):
        if mask[k]:
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth:
                depth -= 1
            else:
                trail += 1
                cut = min(cut, k)
    return lead, opens, t[:cut], trail

def _inline_interp_to_shell(c):
    # GH #801: some pipeline of c runs an inline python/node script stage and, after it, a shell reading stdin.
    # Read on the ANSI-C-decoded text: _pieces does not model \' inside $'..', so a quoted probe string
    # ($'python3 -c \'x\' | bash') would split at its own pipes.
    # GH #815: a { } or ( ) group whose commands run one is such a stage. A shell given a heredoc or here-string
    # (`| bash <<EOF`) is still read as reading the pipe: an over-deny, kept, since a << that is no stdin redirect
    # (2<<, \<\<, ${x:-<<}, $[1<<2], <(cat <<<x)) let a reading of it through. depth: the open groups; the first
    # `marked` of them ran an inline script.
    c = _join_continuations(_normalize_ansi_c_quotes(c) if "$'" in c else c)
    depth = marked = 0
    for s, e in _pieces(c):
        inline = False  # a stage before this one runs an inline script
        for a, b in _pieces(c[s:e], pipe=True):
            g = c[s + a:s + b]
            lead, opens, g, trail = _group_ends(g) if any(ch in g for ch in "(){}") else (0, 0, g, 0)
            for _ in range(lead):
                if depth:
                    depth -= 1
                    inline, marked = inline or depth < marked, min(marked, depth)
            depth += opens
            if inline and "sh" in g.translate(_UNQUOTE) and _reads_stdin_shell(g):
                return True
            if _runs_inline_interp(g):
                inline, marked = True, depth
            for _ in range(trail):
                if depth:
                    depth -= 1
                    inline, marked = inline or depth < marked, min(marked, depth)
    return False

def _shell_stdin_bodies(c):
    # GH #567: the text a stdin-reading shell gets from a here-string in its own segment or from an echo/printf
    # right upstream of it. printf's format is read with \n as a newline; its other escapes stay literal.
    out = []
    for s, e in _pieces(c):
        segs = [c[s + a:s + b] for a, b in _pieces(c[s:e], pipe=True)]
        for k, g in enumerate(segs):
            if not _reads_stdin_shell(g):
                continue
            if "<<<" in g:
                w = _split_words(_decode_quotes(g.split("<<<", 1)[1]))
                if w:
                    out.append(w[0])
            up = _split_words(_decode_quotes(segs[k - 1])) if k else None
            # GH #662: the echo as written past a path, `command [-p] [--]`, `builtin` or busybox [--]
            # (`busybox echo ... | sh`). An index, not slicing: a flood of wrapper words must stay linear.
            # GH #674: and past every other wrapper the rule loop unwraps, assignments too (sudo echo, FOO=1 echo).
            j = _past_run_prefix(up) if up else None
            up = up[j:] if j is not None else None
            name = up[0].rsplit("/", 1)[-1] if up else ""
            if name in ("echo", "printf"):
                args = up[1:]
                while name == "echo" and args and re.fullmatch(r"-[neE]+", args[0]):
                    args = args[1:]
                out.append(" ".join(args).replace("\\n", "\n") if name == "printf" else " ".join(args))
    return out

def _as_words(t):
    # GH #815: the text with $'..' decoded and quotes and backslashes removed, for a name prefilter (s\\h, s''h,
    # $'\\x73h' all name sh; $'\\x70ython3' names python).
    return (_normalize_ansi_c_quotes(t) if "$'" in t else t).translate(_UNQUOTE)

_SHELL_STDIN_BODIES = _shell_stdin_bodies(_join_continuations(cmd)) if any(
    sh in cmd.translate(_UNQUOTE) for sh in _STDIN_SHELLS) else []
# Read on the command lines only: a heredoc body is the reader's text, even one kept as code (cat > x.sh <<'EOF'
# keeps its body, x.sh naming sh), and a script it holds that pipes python -c into bash runs nothing here.
# GH #815: plus the text a shell runs besides them (_CMD_EXTRA, the $(..) bodies of _CMD_EXPANDING), each after a
# `;` line so a trailing | does not join them, and the $(..) and backtick bodies of all of it.
def _interp_pipe_text():
    t = "\n;\n".join((["\n".join(_CMD_LINES)] if _CMD_LINES else [cmd]) + _CMD_EXTRA)
    for b in _CMD_EXPANDING:
        subs = []
        _scan_once(b, subs)
        t += "".join("\n;\n" + x for x in subs)
    return t

_CMD_TEXT = _interp_pipe_text()
_CMD_WORDS = _as_words(_CMD_TEXT)
if any(sh in _CMD_WORDS for sh in _STDIN_SHELLS) and _INLINE_NAME_RE.search(_CMD_WORDS):
    _blown = _DEPTH_BUDGET_BLOWN[0]
    _t = _blank_substitutions(_CMD_TEXT) if ("$(" in _CMD_TEXT or "`" in _CMD_TEXT) else _CMD_TEXT
    _DEPTH_BUDGET_BLOWN[0] = _blown  # this reading leaves the rule loop's budget as it was
    if _inline_interp_to_shell(_t):
        deny("a python -c / node -e / perl -e script pipes its output into a shell, which runs commands the gate "
             "cannot see - write the commands out, or save the output to a file and read it first",
             rule="interp-pipe-shell")

_SQL_BODIES_SEEN = set()  # bash -c / eval bodies already checked by _deny_sql_stdin_drop

def _deny_sql_stdin_drop(c):
    r = _sql_stdin_drop(c)
    if r == "budget":
        deny("command too long to safely read the SQL its { } and ( ) groups pipe into a client - confirm with user first", rule="sql-drop")
    if r:
        deny("destructive SQL (DROP TABLE/DATABASE/SCHEMA or TRUNCATE) sent to a SQL client on stdin — confirm with user first", rule="sql-drop")

_deny_sql_stdin_drop(cmd)

# GH #309: bash, ksh and zsh (not dash) expand a brace inside a word before anything reads it, so
# "git {,\"reset\"} --hard", "--fo{r,}{ce,}" and "r{m,} -rf" hid a verb or flag from every check below,
# which read the text literally. _bracex expands the whole command the way the shell does (lexed, so
# quotes, substitutions and comments stay what they are); the result is read as one more view
# ("brace-view", see _views), checked by every rule. A command the expansion cannot bound (nesting,
# size, a stand-in noncharacter) is a structural deny here, never skipped. Without _bracex the view
# cannot be read at all, so a command that could hold an expansion is denied under brace-view's own id:
# it journals while that rule is shadowed and enforces once it is promoted. Bash expands a brace only
# with a "," or ".." in it, so that test is a superset of every bash expansion (nested ones included); a
# plain ${VAR}, awk '{...}' or find -exec {} is left alone. zsh with braceccl expands r{m} too (GH #665).
# Known over-deny while _bracex is broken: any "{" with a "," or ".." anywhere in the command, inside the
# brace or not (mkdir {a,b}, awk '{print $1, $2}', find .. -exec ls {} +, git log a..b --format={x},
# ${x,,}, a quoted '{a,b}'). Kept coarse on purpose: a narrower text test would be a loosening.
# The else matters: a shadowed deny returns here.
_BRACEX_TEXT = None
if "{" in cmd:
    if _bracex is None:
        if "," in cmd or ".." in cmd:
            deny("brace expansion unavailable (_bracex not importable) - a brace can hide a verb; confirm with user first",
                 rule="brace-view")
    else:
        try:
            _BRACEX_TEXT = _bracex.expand_text(cmd, _CMD_LEN_CAP)
        except (_bracex.TooBig, RecursionError) as _e:
            deny("command too long to safely tokenize (brace expansion: " + str(_e) + ") - confirm with user first")
        if _BRACEX_TEXT == cmd:
            _BRACEX_TEXT = None

# GH #184/#185/#194/#195/#196: the tokenizer mis-closes or never expands these shapes, which hides an
# irrecoverable verb from every check below. Rather than teach it each grammar, fail closed on the raw
# text (pre-blanking) when the command is BOTH ambiguous and names an irrecoverable verb. Over-denies
# are the safe direction. Every test is linear or bounded: the length cap above is the only input bound.
# ponytail: not a parser; a real parser (or a differential fuzz per shape) is the upgrade path.
# GH #219 (named-fd "{var}>") is not a raw-text rule: _blank_redirections reads it both ways instead.
_AMBIG_QUOTED_CLOSE_RE = re.compile(r"\$\([^)\n]{0,80}[\"'][^\"'\n$(]{0,20}\)[^\"'\n$(]{0,20}[\"']")
_AMBIG_BRACE_RE = re.compile(r"(?:^|[\s;|&(])\{[^{}\s\"'`$]{1,60}\}(?=[\s;|&)]|$)")
# GH #275 follow-up: the bundle form splits at the FIRST f/d/D/r/R only (same language as the old
# `[uvnqxfdDrR]*[fdDrR][uvnqxfdDrR]*`); the old form retried every split of a long `-fff...` token.
# Git accepts unique long-option prefixes ("--har", "--forc"), so both spellings are flags here.
_AMBIG_FLAG_RE = re.compile(r"--h(?:a(?:r(?:d)?)?)?\b|--fo(?:r(?:c(?:e)?)?)?\b|(?:^|\s)-[uvnqx]*[fdDrR][uvnqxfdDrR]*\b")
# A brace token can hide a flag ("rm {-rf,} X"), so its verb check is broad (any rm/dd/find/git sub);
# the other shapes leave the flags visible, so their verb check is the destructive form itself.
# GH #269 F1-F4: the verb checks were regexes with length bounds (400 of git globals, 200 between verb and
# flag), so padding walked past them, and the rm test looked at the first flag only. They now cut each
# simple command into one segment (the verb, then units up to a bare ; | & or newline; a quoted or escaped
# span, which may hold those characters, is one unit) with a greedy non-overlapping finditer, which is
# linear, and look for the sub word and the flags anywhere in the segment, from the sub word's FIRST
# occurrence on (a superset of any later one). A segment that meets an unterminated quote or backtick runs
# on to the next bare separator. Over-denial (a sub word used as an argument) only happens once an
# ambiguity shape has already matched, and is the safe direction.
# ponytail: a quoted span over 200 chars that holds a separator ends its segment early; no known payload.
# GIT_VALUE_GLOBALS is the one list of value-taking git globals, used by the main parser below.
GIT_VALUE_GLOBALS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--attr-source", "--config-env")
_AMBIG_UNIT = (r"(?:[^\n;|&'\"\\$`]|\"[^\"\n]{0,200}\"|'[^'\n]{0,200}'|\\."
               r"|\$\([^)\n]{0,200}\)|\$(?!\()|`[^`\n]{0,200}`)")
_AMBIG_SEG_RE = re.compile(r"(?<![\w.-])(rm|g?dd|find|git)(?=\s)" + _AMBIG_UNIT + r"*[^\n;|&]*")
# GH #269 F3: a sub word may sit inside a brace token ("{a=b,push}", "{push,}"), so "{" and "," may precede it.
_AMBIG_GIT_SUB_RE = re.compile(r"(?<![\w.\-/])(push|reset|clean|checkout|restore|switch|branch|stash)\b")
# GH #275 follow-up / GH #284: a bundle like -fu counts as a force flag, and a run of 201+ letters counts as a hit.
_AMBIG_NARROW_AFTER = {
    # GH #349: a +refspec forces too, as the main parser reads it (a lone "+", as in code text, does not).
    "push": re.compile(r"--force\b|\s-[A-Za-z]*f|\s-[A-Za-z]{201}|\s\+\S"),
    "reset": re.compile(r"--h(?:a(?:r(?:d)?)?)?\b"),  # GH #349: a unique prefix (--h, --har), as the main parser reads it
    "clean": re.compile(r""),
    "restore": re.compile(r""),
    # GH #349: a "." word may also end at the close of a substitution (`git checkout .`).
    "checkout": re.compile(r"\s--(?:\s|$)|\s-f\b|\s\.(?=[\s`)]|$)"),
    "branch": re.compile(r"\s-D\b"),
    "stash": re.compile(r"\s+(?:drop|clear)\b"),
    # GH #340: any switch, like clean/restore. A flag piece (-f/--force/--discard-changes) was fuzzed and
    # missed a quoted spelling inside a substitution body ($'-f'), where this check is the only defense.
    "switch": re.compile(r""),
}
# A sub word with no piece above counts as a hit, so a word added to _AMBIG_GIT_SUB_RE alone fails closed.
_AMBIG_ANY = re.compile(r"")
# --r / --f: any long option starting there, so every GNU prefix of --recursive / --force counts.
_AMBIG_RM_FLAG_RE = re.compile(r"\s(?:-[A-Za-z]*[rRf]|--[rf])")
_AMBIG_FIND_RE = re.compile(r"-delete|-exec\w*\s+rm")

class _AmbigVerb:
    """.search(text): does any simple command in text name a broad (or narrow) irrecoverable verb?"""
    def __init__(self, narrow):
        self.narrow = narrow
    def search(self, text):
        for m in _AMBIG_SEG_RE.finditer(text):
            verb, seg = m.group(1), m.group()
            if verb == "git":
                first = {}
                for sm in _AMBIG_GIT_SUB_RE.finditer(seg):
                    first.setdefault(sm.group(1), sm.end())
                if first and not self.narrow:
                    return True
                if any(_AMBIG_NARROW_AFTER.get(v, _AMBIG_ANY).search(seg, e) for v, e in first.items()
                       if not (v == "push" and _FORCE_PUSH_OK)):
                    return True
            elif not self.narrow:
                return True
            elif verb == "rm":
                if _AMBIG_RM_FLAG_RE.search(seg):
                    return True
            elif verb == "find":
                if _AMBIG_FIND_RE.search(seg):
                    return True
            elif "of=" in seg:  # dd
                return True
        return False

_AMBIG_BROAD_VERB_RE = _AmbigVerb(False)
_AMBIG_NARROW_VERB_RE = _AmbigVerb(True)

def _ambiguous(c):
    """(reason, verb_re) when c is syntactically ambiguous, else None."""
    subst = "$(" in c
    # Broad-verb shapes first: every narrow verb match is also a broad one, so a narrow shape
    # returning first would hide a brace-hidden flag in the same command (deep-audit 2026-09-30).
    if _AMBIG_BRACE_RE.search(c):
        return "a brace token", _AMBIG_BROAD_VERB_RE
    if re.search(r"[@~^]\{", c) and _AMBIG_FLAG_RE.search(c):
        return "a flag after a git @{...}/~{...}/^{...} revision", _AMBIG_BROAD_VERB_RE
    if "`" in c and subst:
        return "a backtick and a $() in one command (nested substitution)", _AMBIG_NARROW_VERB_RE
    if "\\`" in c:
        return "an escaped backtick", _AMBIG_NARROW_VERB_RE
    if subst and _AMBIG_QUOTED_CLOSE_RE.search(c):
        return "a quoted ) inside a $()", _AMBIG_NARROW_VERB_RE
    if subst and re.search(r"\bcase\b", c):
        return "a case statement inside a $()", _AMBIG_NARROW_VERB_RE
    if (subst or "`" in c) and re.search(r"\beval\b", c):
        return "eval of a substitution", _AMBIG_NARROW_VERB_RE
    return None

_ambig = _ambiguous(cmd)
def _deny_ambiguous():
    if _VIEW[0]:
        # The raw text was checked above. In a view this rule-less deny only ends the view before any rule ran,
        # so a brace anywhere in the command hid `git${IFS}reset --hard` from ifs-split (GH #718).
        return
    deny("ambiguous shell syntax (" + _ambig[0] + ") next to an irrecoverable verb - confirm with user first")
# The verb is looked for in three views: the raw text, the text with line continuations joined, and the
# text with quotes and backslashes dropped, so '"git" push' and 'r\m' cannot hide it (GH #255).
# GH #349: that last view reads $'-f' as $-f (no blank before the dash), so a narrow flag piece missed it in
# a substitution body. A fourth view decodes $'..' and reads $".." as "..", for every verb rule at once.
_joined = cmd.replace("\\\n", "")
_views = [cmd, _joined, re.sub(r"[\"'\\]", "", _joined)]
if _ambig and ("$'" in _joined or '$"' in _joined):
    _views.append(re.sub(r"[\"'\\]", "", re.sub(r"\$(?=\")", "", _normalize_ansi_c_quotes(_joined))))
if _ambig and any(_ambig[1].search(v) for v in _views):
    _deny_ambiguous()

try:
    tokens = _tokens(_blanked(cmd))
except ValueError:
    # Two causes: (1) a genuinely unbalanced quote; (2) the closer-search above
    # does not track quotes INSIDE a span, so a span crossing a quote char
    # desyncs quote state on a valid command. Re-parse the ORIGINAL cmd as a
    # predicate: if it parses, the error is self-inflicted (2) and a separator-
    # aware split of the SAME blanked pipeline is used (never the raw cmd: every
    # downstream PH check assumes blanked tokens, and a bare split glues
    # "};git"). ( ) { } are excluded: inside ${...} they are usually literal.
    # If the original also fails to parse, deny on ambiguity.
    try:
        shlex.split(cmd)
        _fallback_src = _blanked(cmd)
        parts = re.split(r"(&&|\|\||;|\||&)", _fallback_src)
        tokens = []
        for part in parts:
            if part in ("&&", "||", ";", "|", "&"):
                tokens.append(part)
            else:
                tokens.extend(part.split())
    except ValueError:
        deny("could not safely tokenize command for pattern matching (unbalanced quote/substitution) - confirm with user first")

# A scan that could not finish left a span un-blanked -- deny before dispatch.
def _deny_if_depth_blown():
    if isinstance(_DEPTH_BUDGET_BLOWN[0], str):
        deny(_DEPTH_BUDGET_BLOWN[0])
    if _DEPTH_BUDGET_BLOWN[0]:
        deny("could not safely tokenize command (nested substitution exceeded the depth-scan budget, or a funsub body has an unbalanced quote) - confirm with user first")
_deny_if_depth_blown()

# GH #254: a "{" or "}" inside a word is literal in bash ("feat{1}"), but shlex splits the word there
# and the split opens a new window, so "git reset feat{1} --hard" left "--hard" in a window of its own.
# A second tokenization keeps braces inside words (a whole-token "{"/"}" still splits, as bash
# grouping needs), and its windows are checked too: a deny from either copy wins, so this only adds.
_token_lists = [tokens]
if "{" in cmd or "}" in cmd:
    try:
        _token_lists.append(_tokens(_blanked(cmd), "{}"))
        # GH #219: the same text read the macOS sh / bash 3.2 / dash way, "{var}>f" a literal word.
        for _nf in (False, "zsh"):
            _token_lists.append(_tokens(_blanked(cmd, _nf), "{}"))
    except ValueError:
        pass  # the first copy already handled an unparsable command

windows = []
_seen_windows = set()  # GH #268: the second copy skips a window the first already holds, so the budget charges it once
for _i, _toks in enumerate(_token_lists):
    for cur, _ww in _readings(_toks):
        if _ww:
            _queue_words(_ww, 0)
        if cur and not (_i and tuple(cur) in _seen_windows):
            if not _i:
                _seen_windows.add(tuple(cur))
            windows.append(cur)

# A standalone substitution resolving to empty ($(true)) vanishes as a token in
# bash, shifting later tokens left, but leaves a PH-only token here, so every
# fixed-index read (stash args[0], the git subcommand slot) sees the wrong slot.
# Each window is also dispatched as a compacted copy with bare-PH tokens
# dropped; a deny in either copy wins ("$(which git) status" -> ["status"]).
_aug = []
for _w in windows:
    _wc = _drop_ph_tokens(_w)
    _aug.append(_w)
    if _wc != _w:
        _aug.append(_wc)
windows = _aug

def basename(p):
    return p.rsplit("/", 1)[-1]

def _past_dash_words(rest, i=0):
    # Index of the first word from i on that does not start with "-" once placeholders are stripped.
    while i < len(rest) and rest[i].replace(PH, "").startswith("-"):
        i += 1
    return i

# One-level unwrap of `bash|sh|zsh|dash|ksh -c "<body>"` and `eval <body>`: the
# quoted body is a command line, so it is re-tokenized into windows of its own,
# appended to `windows` while the main loop runs (a list picks up items appended
# mid-iteration). Called AFTER the prefix-wrapper unwrap so `sudo bash -c` opens
# too. Nested bodies (`sh -c "sh -c '...'"`, GH #227) unwrap again, each level
# recorded in _WDEPTH; a body still nested past _MAX_SHELL_DEPTH is denied
# rather than left unscanned. The outer tokenizer
# stripped the quotes but blanked substitutions only inside a DOUBLE-quoted body
# (a single-quoted one is inert to the outer shell and live to the inner), so
# the body is blanked again here and its PH tokens duplicate-classify below.
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "hush"}  # ash, hush: busybox (GH #662)
_MAX_SHELL_DEPTH = 5
_WDEPTH = {}      # window index -> unwrap depth (absent = 0, an original window)
_XARGS_HANDOVERS = [0]  # windows appended for `xargs <wrapper> ...` (bounded, see the xargs branch)
_ENV_PRE570_WINDOWS = set()  # indexes of the GH #560 pre-#570 env -S readings (see the env branch)
_cur_depth = 0

def _count_handover(what):
    _XARGS_HANDOVERS[0] += 1
    if _XARGS_HANDOVERS[0] > 50:
        deny("more than 50 chained " + what + " wrappers - too complex to scan safely, confirm with user first")

def _shell_body(argv0, rest, getopt, need_c=True):
    """The `-c` command string of `argv0 rest`, or None. `getopt` picks how a value flag reads:
    bash (and dash, ash) takes the next word for EVERY o/O in a cluster (`-oc pipefail`, `-coo a b`); zsh
    and ksh follow getopt, where an `o` followed by more letters has them as its attached value
    (`-opipefail`) and only a cluster-final `o` takes the next word. zsh's -O takes none."""
    vf = "o" if argv0 == "zsh" else "oO"

    def cluster(letters, sign):  # -> (has -c, following words consumed)
        c, extra = False, 0
        for k, ch in enumerate(letters):
            if ch == "c":  # GH #662: `+c CMD` runs CMD too (bash, dash, busybox ash)
                c = True
            if ch in vf:
                if not getopt:
                    extra += 1
                    continue
                extra += 1 if k == len(letters) - 1 else 0
                break
        return c, extra

    # The -c may sit anywhere in a `-` cluster (`-Oc`; `-exec` is the letters e,x,e,c), and the
    # tokenizer splits `+e` / `+o name` into `+` and the letters. The body is the first word after
    # the options; `--` / a bare `-` end them.
    i, seen_c = 0, False
    while i < len(rest):
        u = rest[i].replace(PH, "")
        if u in ("--", "-"):
            i += 1
            break
        if u == "+" and i + 1 < len(rest) and rest[i + 1].replace(PH, "").isalpha():
            i += 2 + cluster(rest[i + 1].replace(PH, ""), "+")[1]
        elif len(u) > 1 and u[0] in "-+" and not u.startswith("--"):
            c, extra = cluster(u[1:], u[0])
            seen_c = seen_c or c
            i += 1 + extra
        elif u.startswith("--") and len(u) > 2:
            i += 2 if u in _LONG_VALUE_OPTS else 1
        else:
            break
    if seen_c and i < len(rest):
        return rest[i]
    if not need_c and i < len(rest):
        return " ".join(rest[i:])  # ksh joins every operand word into the command string
    # Fallback (a script word before -c, `--rcfile FILE -c body`): the first `-c` cluster anywhere.
    for i in range(len(rest) - 1):
        t = rest[i].replace(PH, "")
        if t[:1] in ("-", "+") and not t.startswith("--") and "c" in t:
            j = i + (2 if t[-1] in vf else 1)
            while j < len(rest):
                u = rest[j].replace(PH, "")
                if u in ("--", "-"):
                    j += 1
                    break
                if len(u) > 1 and u[0] in "-+":
                    j += 2 if ((u[-1] in vf and not u.startswith("--")) or u in _LONG_VALUE_OPTS) else 1
                    continue
                break
            return rest[j] if j < len(rest) else None
    return None


_LONG_VALUE_OPTS = ("--rcfile", "--init-file")  # bash long options that take a file: the next word is not the body


# bash reads every o/O in a cluster as taking the next word; zsh and ksh follow getopt; `sh` is
# bash on macOS and dash on Linux, so both readings are scanned (a wrong reading only scans one
# extra word). dash and busybox ash take the next word for every o too (`dash -oc errexit 'cmd'`
# runs cmd, checked live, GH #662), so they are scanned both ways as well; hush has no -o.
_SHELL_GETOPT = {"bash": (False,), "zsh": (True,), "ksh": (True,), "dash": (False, True), "sh": (False, True),
                 "ash": (False, True), "hush": (True,)}


# GH #608: an interpreter one-liner (python -c, perl/ruby -e, node -e/-p) runs a command through a string it
# hands to a process API: os.system("rm -rf x"), subprocess.run(["git", "push", "--force"]), `git reset
# --hard` in perl/ruby. When the body names such an API, each string literal, and each comma-separated run
# of literals (an argv list) joined by blanks, is scanned as a shell command line. A body with no process API
# is not read, so print("rm -rf is denied") stays allowed. API deletes (shutil.rmtree, fs.rmSync) are unseen.
_INTERP_BODY_FLAGS = {"python": ("-c",), "perl": ("-e", "-E"), "ruby": ("-e",), "node": ("-e", "--eval", "-p", "--print")}
_INTERP_NAME_RE = re.compile(r"(python)[23]?(?:\.\d+)?|(perl)(?:5[\d.]*)?|(ruby)[\d.]*|(node)(?:js)?")
# GH #741: asyncio's create_subprocess_shell/exec and posix_spawn(p) (a bare name in a -c body, a call in a heredoc
# script, GH #741 review 3), and a process module reached by name
# (getattr(os, ...), importlib.import_module("os"), __import__("subprocess")), where the call is built at run time.
# A getattr whose name is one plain literal naming no process API (getattr(os, "sep")) is no call (GH #741 review).
_PROC_BY_NAME = (r"|\bgetattr\s*\(\s*(?:os|posix|subprocess|asyncio|pty)\b(?!\s*\.)(?!\s*,\s*([\"'])(?!(?:system|popen\d?|spawn\w*|exec\w*|"
                 r"posix_spawnp?|fork\w*|run|call|check_\w+|Popen|getoutput|getstatusoutput|create_subprocess_\w+)\1)\w+\1\s*[,)])"
                 r"|\b(?:import_module|__import__)\s*\(\s*[\"'](?:os|posix|subprocess|asyncio|pty|child_process)[\"']"
                 # GH #801: read at once as an attribute that names no process API (__import__('os').path) it is no
                 # call built at run time; .system, .execvp etc. still count, stored or called (f = ....system)
                 r"(?!\s*\)\s*\.\s*(?!(?:system|popen\d?|spawn\w*|exec\w*|posix_spawnp?|fork\w*|run|call|check_\w+|"
                 r"Popen|getoutput|getstatusoutput|create_subprocess_\w+)\b)[A-Za-z])")
_INTERP_PROC_RE = re.compile(r"\b(?:system|popen\d?|subprocess|check_output|check_call|Popen|getoutput|getstatusoutput|"
                             r"exec[lv]?[pe]{0,2}|execSync|execFileSync|execFile|spawn\w*|child_process|qx|pty)\b|%x|`"
                             r"|\b(?:create_subprocess_(?:shell|exec)|posix_spawnp?)\b" + _PROC_BY_NAME)
# GH #681: a whole python/node heredoc script is often a docs edit whose prose says spawn, exec or system and
# holds markdown backticks (no API in python/node), so it is read only when it names a module or calls a
# function that runs a process.
_PYNODE_PROC_RE = re.compile(r"\b(?:subprocess|child_process|execSync|execFileSync|execFile|spawnSync|getoutput|"
                             r"getstatusoutput|check_output|check_call|Popen|pty)\b"
                             r"|\b(?:system|popen\d?|spawn\w*|exec[lv]p?e?|posix_spawnp?|create_subprocess_(?:shell|exec))\s*\("
                             # GH #815: stored and called later (f = os.system; from os import system as run)
                             r"|\b(?:os|posix)\s*\.\s*(?:system|popen\d?|spawn\w*|exec[lv]p?e?|posix_spawnp?)\b"
                             r"|\bfrom\s+(?:os|posix)\s+import\b[^\n]*\b(?:system|popen\d?|spawn\w*|exec[lv]p?e?|posix_spawnp?)\b"
                             + _PROC_BY_NAME)
_INTERP_LIT_RE = re.compile("'''(?:.|\\n)*?'''|\"\"\"(?:.|\\n)*?\"\"\"|'(?:[^'\\\\\\n]|\\\\.)*'|\"(?:[^\"\\\\\\n]|\\\\.)*\"|`[^`]*`"
                            r"|\bqx\s*([{(\[<|/!])|%x\s*([{(\[<|/!])")
_INTERP_CLOSE = {"{": "}", "(": ")", "[": "]", "<": ">"}

def _interp_body(argv0, rest):
    m = _INTERP_NAME_RE.fullmatch(argv0)
    if not m:
        return None
    flags = _INTERP_BODY_FLAGS[next(g for g in m.groups() if g)]
    for i, t in enumerate(rest):
        t = t.replace(PH, "")
        if t == "--":
            return None
        name, eq, val = t.partition("=")
        if t in flags or (name in flags and name.startswith("--") and eq):
            return val if eq else (rest[i + 1] if i + 1 < len(rest) else None)
        # a short cluster holding the body letter (perl -ne, -pe), the body attached after it (python -cprint(1))
        if t.startswith("-") and not t.startswith("--"):
            for f in flags:
                if not f.startswith("--") and f[1] in t[1:]:
                    k = t.index(f[1], 1)
                    return t[k + 1:] or (rest[i + 1] if i + 1 < len(rest) else None)
        if not t.startswith("-"):
            return None  # a script file: its code is unseen
    return None

def _emit_run(run, out):
    if len(run) > 1:
        out.append(" ".join(run))
    # GH #741: exec*/spawn*/posix_spawn* take the program path, then its argv (execvp("git", ["git", "reset",
    # "--hard"]), execv("/usr/bin/git", ["git", ...])): when the second literal names the first one's program, the
    # argv from it on is read too. Only then, so subprocess.run(["echo", "rm", "-rf", "x"]) stays an echo.
    if len(run) > 2 and run[1] and run[0].rsplit("/", 1)[-1] == run[1].rsplit("/", 1)[-1]:
        out.append(" ".join(run[1:]))

def _interp_commands(body):
    # The command lines a process-API body may run: each literal, and each comma-joined run of literals.
    if not _INTERP_PROC_RE.search(body):
        return []
    lits, i, out = [], 0, []
    while True:
        m = _INTERP_LIT_RE.search(body, i)
        if not m:
            break
        if m.group(1) or m.group(2):  # qx{...} / %x(...): read to the matching closer
            op = m.group(1) or m.group(2)
            j = body.find(_INTERP_CLOSE.get(op, op), m.end())
            j = len(body) if j < 0 else j
            lits.append((m.start(), j + 1, body[m.end():j]))
            i = j + 1
            continue
        t = m.group()
        q = 3 if t[:3] in ("'''", '"""') else 1
        lits.append((m.start(), m.end(), t[q:len(t) - q]))
        i = m.end()
    run = []
    for k, (a, b, text) in enumerate(lits):
        out.append(text)
        # a comma between two literals, with brackets around it: ("git", ["push", "--force"]) is one argv
        if run and re.fullmatch(r"[\s\[\](){}]*,[\s\[\](){}]*", body[lits[k - 1][1]:a]):
            run.append(text)
        else:
            _emit_run(run, out)
            run = [text]
    _emit_run(run, out)
    return out

def _unwrap_shell(argv0, rest):
    if argv0 == "eval":
        bodies = [" ".join(rest)] if rest else []
    elif argv0 in _SHELLS:
        bodies = []
        for g in _SHELL_GETOPT[argv0]:
            b = _shell_body(argv0, rest, g)
            if b and b not in bodies:
                bodies.append(b)
        if argv0 == "ksh":
            # ksh93 runs a first operand that is not a readable file as the command string and joins
            # the later words into it (`ksh 'echo a' --hard` runs `echo a --hard`; a later -c is part
            # of that string). A script name scans as harmless text, so it is read as a body too.
            # -s (commands from stdin), -n (no execution) and -D (print strings) run no operand. Only the
            # leading `-` clusters count, each up to an o/R (the rest, or the next word, is its value:
            # `-onounset` sets no -n); a `+` option can turn one back off, so it keeps the scan.
            lead, skip = "", False
            for t in rest:
                u = t.replace(PH, "")
                if skip:
                    skip = False
                    continue
                if u.startswith("+"):  # `-n +n` / `-n +o noexec` run the operand again
                    lead = ""
                    break
                if u in ("--", "-") or len(u) < 2 or u[0] != "-" or u.startswith("--"):
                    break
                letters = re.split("[oR]", u[1:], maxsplit=1)
                lead += letters[0]
                skip = len(letters) > 1 and not letters[1]
            b = None if any(ch in "snD" for ch in lead) else _shell_body(argv0, rest, True, need_c=False)
            if b and b not in bodies:
                bodies.append(b)
    else:
        return
    if argv0 != "eval":
        for body in list(bodies):
            filled = _positional_body(body, rest)
            if filled is False:
                deny("shell -c body with its arguments filled in is too long to scan safely - confirm with user first")
            if filled and filled not in bodies:
                bodies.append(filled)
    for body in bodies:
        _scan_body(body)

# GH #663: `sh -c BODY ARG0 ARGS...` runs BODY with $0 = ARG0 and $1.. / "$@" / $* = ARGS, so
# `bash -c 'rm "$@"' -- -rf b` runs `rm -rf b`. A copy of the body with each positional parameter expanded as the
# shell would is read as well (the body as written stays read too). The body is walked with its quote state:
# in single quotes nothing expands; in double quotes a value is inserted escaped (a message stays a message,
# `"-$1"` still makes a flag), and "$@" becomes one quoted word per argument; unquoted, a value is split on
# blanks and each piece is shell-quoted, so `-$1`, `r$1`, `$1$2` and a value of `rm -rf b` read as the shell
# runs them while a value's `;` is never a separator. A double-quoted body keeps the outer shell's backslash
# before a $ or backtick, which is dropped first. Operators (defaults, # % patterns, case, /x/y, substrings,
# @ slices) are applied; an unknown one gives the plain value. A leading `shift [N]` drops arguments.
# GH #663 review 5: each redirect is matched atomically (a lookahead captured, then consumed by backreference)
# and its target stops at the next operator, so glued `<a<a<a...` redirects cannot backtrack exponentially.
_POSITIONAL_SHIFT_RE = re.compile(
    r"\s*shift(?:\s+(\d+))?(?:(?=(\s*\d*[<>]&?\s*[^\s<>;&|]+))\2)*\s*(?:;|&&|\|\|[^;&|\n]*(?:;|&&|\n)|\n)")
_POSITIONAL_PARAM_RE = re.compile(r"\$([@*#0-9])")
_POSITIONAL_NAME_RE = re.compile(r"(!#|[@*#]|\d+)")
_POSITIONAL_SLICE_RE = re.compile(r":\s*\(?\s*(-?\d+)\s*\)?(?::\s*\(?\s*(-?\d+)\s*\)?)?")
_POSITIONAL_CAP = 150_000  # characters of work across the whole command; past it the command denies
_POSITIONAL_CUT_MAX = 4096  # a # % pattern cut on a longer value denies (the cut is O(n^2))
_POSITIONAL_SPENT = [0]

class _PositionalOverCap(Exception):
    pass

def _positional_charge(n):
    _POSITIONAL_SPENT[0] += n
    if _POSITIONAL_SPENT[0] > _POSITIONAL_CAP:
        raise _PositionalOverCap

def _positional_pattern(pat):
    # A # % / pattern as bash reads it: quotes and backslashes removed, `[^` the same as `[!`.
    pat = re.sub(r"""\\(.)|'([^']*)'|"((?:[^"\\]|\\.)*)\"""", lambda m: re.sub(r"([*?\[])", r"[\1]",
                 m.group(1) if m.group(1) is not None else m.group(2) if m.group(2) is not None
                 else re.sub(r"\\(.)", r"\1", m.group(3))), pat)
    return pat.replace("[^", "[!")

def _positional_op(vals, op, is_list, expand):
    # One bash parameter operator applied to the value(s). A default or alternate word is itself expanded
    # (`${1+"$@"}`, `${3:-$2}`); an operator not modelled gives the values unchanged.
    import fnmatch
    v = " ".join(vals)
    m = re.fullmatch(r"(:?)([-=?+])(.*)", op, re.S)
    if m:
        unset = not vals or (m.group(1) and not v)
        if m.group(2) == "+":
            return None if unset else expand(m.group(3))
        return expand(m.group(3)) if unset and m.group(2) in "-=" else vals
    m = _POSITIONAL_SLICE_RE.fullmatch(op)
    if m:  # ${@:k[:n]} / ${1:k[:n]}
        k, n = int(m.group(1)), (int(m.group(2)) if m.group(2) is not None else None)
        seq = vals if is_list else v
        part = seq[k:] if k >= 0 else seq[len(seq) + k:] if -k <= len(seq) else seq[:0]
        part = part if n is None else part[:n]
        return list(part) if is_list else [part]
    def each(f):
        return [f(x) for x in vals]
    m = re.fullmatch(r"(##?|%%?)(.*)", op, re.S)
    if m:
        pat, longest, front = _positional_pattern(m.group(2)), len(m.group(1)) == 2, m.group(1)[0] == "#"
        def cut(x):
            if len(x) > _POSITIONAL_CUT_MAX:  # too long to cut cheaply: deny rather than read the raw value
                raise _PositionalOverCap
            _positional_charge(len(x) * len(x) // 64 + 1)
            cuts = [i for i in range(len(x) + 1) if fnmatch.fnmatchcase(x[:i] if front else x[i:], pat)]
            if not cuts:
                return x
            i = (max(cuts) if longest else min(cuts)) if front else (min(cuts) if longest else max(cuts))
            return x[i:] if front else x[:i]
        return each(cut)
    case = {",,": str.lower, "^^": str.upper, ",": lambda x: x[:1].lower() + x[1:], "^": lambda x: x[:1].upper() + x[1:]}
    if op in case:
        return each(case[op])
    m = re.fullmatch(r"/([/#%]?)((?:[^/\\]|\\.)*)(?:/(.*))?", op, re.S)
    if m:
        kind, pat, rep = m.group(1), _positional_pattern(m.group(2)), m.group(3) or ""
        rx = re.compile(fnmatch.translate(pat)[4:-3] if pat else "", re.S)  # (?s:...)\Z -> the bare pattern
        def sub(x):
            if pat:  # GH #663 review 5: a pattern match is O(n^2) on a leading *, bounded as a cut is
                if len(x) > _POSITIONAL_CUT_MAX:
                    raise _PositionalOverCap
                _positional_charge(len(x) * len(x) // 64 + 1)
            if kind == "#":
                hit = rx.match(x)
                return rep + x[hit.end():] if hit else x
            if kind == "%":
                hit = re.search("(?:" + rx.pattern + r")\Z", x, re.S)
                return x[:hit.start()] + rep if hit else x
            if not pat:
                return x
            _positional_charge(len(rx.findall(x)) * len(rep) + len(x))  # the result's size, before it is built
            return rx.sub(lambda _m: rep, x) if kind == "/" else rx.sub(lambda _m: rep, x, count=1)
        return each(sub)
    return vals

def _brace_end(t, i):
    # The index just past the `}` closing the `{` at t[i], counting nested braces; -1 when unclosed.
    depth, j, n = 1, i + 1, len(t)
    start = j
    while j < n:
        c = t[j]
        if c == "\\":
            j += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if not depth:
                _positional_charge(j - start)
                return j + 1
        j += 1
    _positional_charge(j - start)  # an unclosed ${ scans to the end: counted, so a flood of them hits the cap
    return -1

def _pos_expand(text, args, quoted):
    # The text with every positional parameter expanded, walking its quote state (see _positional_body).
    # Returns (expanded text, whether a parameter was found).
    words, pos = args
    out, i, n, quote, found = [], 0, len(text), '"' if quoted else None, False
    while i < n:
        c = text[i]
        if quote in (SQ, "$'"):
            if quote == "$'" and c == "\\" and i + 1 < n:
                out.append(text[i:i + 2])
                i += 2
                continue
            quote = None if c == SQ else quote
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if quote is None and c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            j = text.find("\n", i)  # a comment runs to the end of the line, quotes and all
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
            continue
        if quote is None and c == "$" and text[i + 1:i + 2] == SQ:
            quote = "$'"
            out.append("$'")
            i += 2
            continue
        if c == SQ and quote is None or c == '"' and not quoted:
            quote = SQ if c == SQ else None if quote == '"' else '"'
            out.append(c)
            i += 1
            continue
        if quote == '"' and c == "`":  # a backtick inside "...": copied whole, its quotes are its own
            j = text.find("`", i + 1)
            j = n - 1 if j < 0 else j
            out.append(text[i:j + 1])
            i = j + 1
            continue
        if c != "$":
            out.append(c)
            i += 1
            continue
        if quote == '"' and text[i + 1:i + 2] == "(":  # a $(...) inside "...": copied whole by depth
            depth, j = 0, i + 1
            while j < n:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                if not depth:
                    break
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            _positional_charge(j - i)
            i = j + 1
            continue
        if text[i + 1:i + 2] == "{":
            end = _brace_end(text, i + 1)
            nm = _POSITIONAL_NAME_RE.match(text, i + 2) if end > 0 else None
            if not nm:
                out.append(c)
                i += 1
                continue
            name, op, nxt = nm.group(1), text[nm.end():end - 1], end
        else:
            m = _POSITIONAL_PARAM_RE.match(text, i)
            if not m:
                out.append(c)
                i += 1
                continue
            name, op, nxt = m.group(1), "", m.end()
        found = True
        if name in "@*":  # a ${@:k} slice counts $0 as position 0; every other form starts at $1
            vals, is_list = ([words[0]] + pos if _POSITIONAL_SLICE_RE.fullmatch(op) else list(pos)), True
        elif name == "#":
            vals, is_list = [str(len(pos))], False
        elif name == "!#":
            vals, is_list = [pos[-1] if pos else words[0]], False
        else:
            num = int(name)
            vals = [words[0]] if num == 0 else ([pos[num - 1]] if num - 1 < len(pos) else [])
            is_list = False
        raw = False
        if op:
            res = _positional_op(vals, op, is_list, lambda w: [_pos_expand(w, args, quote == '"')[0]])
            vals, raw = ([] if res is None else res), op[:2].lstrip(":")[:1] in ("-", "=", "+") and res is not vals
        if raw:  # an expanded default word is already shell text
            text_out = " ".join(vals)
        elif quote == '"':
            esc = [re.sub(r'([\\"$`])', r"\\\1", x) for x in vals]
            text_out = '" "'.join(esc) if name == "@" else " ".join(esc)
        elif re.search(r"(?:^|[\s;&|(])[A-Za-z_]\w*\+?=\S*$", "".join(out[-3:])):  # an assignment's value: no split
            text_out = shlex.quote(" ".join(vals))
        else:
            text_out = " ".join(shlex.quote(p) for x in vals for p in x.split())
            # An empty expansion glued to more of its word (`$9#`) leaves that word, which is no comment; a
            # standalone one vanishes, as in bash (`$9 rm -rf b` runs rm).
            if not text_out and nxt < n and text[nxt] not in " \t\n;&|()<>":
                text_out = "''"
        _positional_charge(len(text_out))
        out.append(text_out)
        i = nxt
    return "".join(out), found

def _positional_body(body, rest):
    k = next((k for k, t in enumerate(rest) if t is body), None)
    if k is None or k + 1 >= len(rest) or "$" not in body:
        return None
    # A double-quoted outer body keeps the outer shell's backslash before $ and backtick: drop it, unless the
    # body has an unescaped parameter of its own (then `\$` is the body's own escape for a nested shell).
    if not re.search(r"(?<!\\)\$(?:[@*#0-9]|\{)", body):
        body = re.sub(r"\\([$`])", r"\1", body)
    words = [t.replace(PH, "") for t in rest[k + 1:]]
    pos = words[1:]
    m = _POSITIONAL_SHIFT_RE.match(body)
    while m:  # `shift; git $1 $2` reads the words after the shifted ones; a shift past $# fails and keeps them
        cnt = int(m.group(1) or 1)
        pos = pos[cnt:] if cnt <= len(pos) else pos
        m = _POSITIONAL_SHIFT_RE.match(body, m.end())
    try:
        filled, found = _pos_expand(body, (words, pos), False)
    except _PositionalOverCap:
        return False
    return filled if found else None


_MAIN_STATEMENTS = set()  # GH #798: the statements of each body the main reading spawn-scanned
_VAR_SPAWN_TEXTS = set()  # GH #798: var-verb's in-order copy, the one spawn-scanned
_VIEW_TEXT = [None]  # the text of the view being read

def _view_spawns():
    # GH #798: the views whose spawns deny: not brace-view (GH #661: its copies spent the budget on legal commands;
    # a brace-built spawn is GH #731), and of var-verb only the in-order copy (each other copy turned a reused
    # variable into claude in one order or the other).
    return _VIEW[0] != "brace-view" and (_VIEW[0] != "var-verb" or _VIEW_TEXT[0] in _VAR_SPAWN_TEXTS)

_PIPE_ONLY_RE = re.compile(r"\s*(\|&?)\s*(?:#.*)?")  # a line holding only a pipe, or a pipe and a comment

def _text_statements(text):
    # The statements of text, split at each unquoted ; & | and newline (_quote_mask). A pipe `|` / `|&` stays at the
    # start of the statement after it, so _nested_spawn's pipe-in check sees a claude that reads stdin (GH #804:
    # `X=claude; echo hi | $X`); `||` is one separator, so `true || $X` is not read as piped.
    # A pipe that ends a line goes on past blank lines or a comment: it is carried to the next line's statement as
    # `| ` (GH #810: `echo hi |` then `$X` on the next line). A backslash-newline is masked, so no split is made there.
    # GH #820 item 3: a statement inside a compound command a pipe feeds (`echo hi | if x; then $X; fi`) reads that
    # stdin too, so it starts with `| ` as well.
    mask, out, start, i, carry = _quote_mask(text), [], 0, 0, ""
    spans = _piped_compound_spans(text, mask) if "|" in text else []
    def fed(st, at):
        return "| " + st if spans and not st.lstrip().startswith("|") and any(o <= at < e for o, e, _ in spans) else st
    while i < len(text):
        ch = text[i]
        if ch in ";&|\n" and not mask[i]:
            pipe = ch == "\n" and _PIPE_ONLY_RE.fullmatch(carry + text[start:i])
            if pipe:
                carry, start, i = pipe.group(1) + " ", i + 1, i + 1
                continue
            out.append(fed(carry + text[start:i], start))
            carry = ""
            if ch == "|" and text[i + 1:i + 2] == "|":
                i += 1
                start = i + 1
            elif ch == "|":
                start = i
                i += text[i + 1:i + 2] == "&"
            else:
                start = i + 1
        i += 1
    out.append(fed(carry + text[start:], start))
    return out


_BODY_VAR_QUEUE = {}  # GH #812: the bodies the main reading scanned, read again with their variables (_scan_body_vars)

def _scan_body(body):
    if not body:
        return
    if _cur_depth >= _MAX_SHELL_DEPTH:
        deny("shell -c / eval body nested more than %d levels deep - confirm with user first" % _MAX_SHELL_DEPTH)
    # GH #559 review: SQL a client reads on stdin inside the body (bash -c "echo 'DROP TABLE t' | psql db"),
    # which the top-level check above read as one quoted word. Heredocs in the body count too.
    # The same body comes back from every window copy (see _BODY_READINGS), so each is checked once.
    if body not in _SQL_BODIES_SEEN:
        _SQL_BODIES_SEEN.add(body)
        # Stripped for the SQL check only (the rules read the body whole), so it records no kept bodies.
        _deny_sql_stdin_drop(_strip_heredocs(body))
    # All three passes (GH #248). This runs inside the rule loop, so the quadratic passes could push
    # a later deny past the hook timeout; _SPAWN_ANCHOR_BUDGET bounds them and denies when over.
    # GH #798: views scan bodies too, and a spawn a view finds denies (_deny_nested_spawn exits; a rule-less deny()
    # only ended the view, so `bash${IFS}-c 'claude -p x'` and `X=claude; bash -c "$X -p x"` passed). Views charge
    # their own budget, reset before the first view (GH #691: sharing the main reading's let padding stop a view).
    # A view re-scans only a body the main reading did not (its own rewrite); the main reading's are recorded.
    # In a view only the body's statements the main reading did not scan are read, once across the views (review:
    # whole rewritten bodies, one per var-verb copy, spent the views' budget on 5 KB scripts). Not brace-view
    # (GH #661) or var-verb (its order-blind first value made `BIN=claude .. BIN=python3; $BIN -c` a spawn; the
    # spawn reading in order is _ordered_var_text).
    if "agent_id" in d and not _ONLY_RULE_PASS_ON[0]:
        if not _VIEW[0]:
            _MAIN_STATEMENTS.update(_text_statements(body))
            if _nested_spawn(body, False) or _nested_spawn(body, True) or _nested_spawn(body, 2) or _subst_spawn(body):
                if _spawn_over_budget:
                    _deny_nested_spawn()  # the "too dense" message, not the spawn one (GH #798)
                deny(_SPAWN_DENY_REASON + ", inside bash -c / eval either")
            if "$" in body:
                _BODY_VAR_QUEUE[body] = None  # a dict: each body once, in order
        elif _view_spawns():
            _scan_view_statements(body)
    readings, blown, bad = _body_readings(body)
    for cur, ww, curc in readings:
        if ww:
            _queue_words(ww, _cur_depth + 1)
        if not cur:
            continue
        _WDEPTH[len(windows)] = _cur_depth + 1
        windows.append(cur)
        if curc != cur:
            _WDEPTH[len(windows)] = _cur_depth + 1
            windows.append(curc)
    if blown:
        _DEPTH_BUDGET_BLOWN[0] = _DEPTH_BUDGET_BLOWN[0] or blown  # GH #702: a body's reason string survives
    if bad:
        deny("could not safely tokenize the body of a bash -c / eval string - confirm with user first")
    _deny_if_depth_blown()

# The same body comes back from every copy of its window (token and word readings, the "{}" token
# lists, the views) and again at each eval / sh -c level, so its readings are made once per run. Only
# the reading is cached; every window is still appended and checked, so each rule, budget and counter
# runs as before. (readings, depth budget blown, unparsable) -> bad stops the list where _tokens raised.
_BODY_READINGS = {}
def _body_readings(body):
    r = _BODY_READINGS.get(body)
    if r is None:
        readings, bad, saved = [], False, _DEPTH_BUDGET_BLOWN[0]
        _DEPTH_BUDGET_BLOWN[0] = False
        try:
            # GH #219: "{var}>f" is a redirect in bash 4+/ksh/zsh and a literal word plus a redirect in
            # macOS sh, bash 3.2 and dash, so a body holding "{" is read both ways and every window checked.
            for nf in ((True, False, "zsh") if "{" in body else (True,)):
                for cur, ww in _readings(_tokens(_blanked(body, nf), whitespace_split=True)):
                    readings.append((cur, ww, _drop_ph_tokens(cur) if cur else cur))
        except ValueError:
            bad = True
        r = _BODY_READINGS[body] = (readings, _DEPTH_BUDGET_BLOWN[0], bad)
        _DEPTH_BUDGET_BLOWN[0] = saved or r[1]
    return r

# GH #585: devices dd may write to (the `dd ... of=/dev/null` benchmark), and an `of=` value under a
# directory variable that names no device (`of=$PWD/out.img`); a `..` after it could climb to /dev.
# `${HOME}` is blanked to a substitution before the rules read it, so only the plain spelling counts.
_DD_SAFE_DEVICES = ("/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/tty")
_DD_SAFE_VAR_RE = re.compile(r"\$(?:PWD|HOME|TMPDIR)/(?:(?!\.\.)[^$`])*$")

# Candidate names for placeholder-splice duplication: the exact argv0 basenames
# and git subcommands any check below dispatches on by exact string match.
KNOWN_DANGEROUS = ("rm", "find", "git", "gh", "dd", "gdd", "mysql", "psql", "sqlite3", "mariadb")
# A pathspec that names the whole tree (GH #289, #308, #315). Magic is parsed as git does: ":(...)",
# or ":" then a run of "/", "!", "^" ended by an optional ":" ("::.", "://", ":/:"). The rest is
# collapsed lexically as git does ("x/.." drops x, "." and "//" drop out); nothing left, or one
# run of "*" ("?*" too), is the whole tree. A ".." left over names an ancestor dir, the whole tree
# from a subdir, so ".." alone is denied too. Exclude magic is left to _exclude_only_pathspecs.
# Over-denies on purpose: ":/." and ":/src/.." (top magic) select nothing in git 2.55, and
# ":(attr:x)" or ":(literal)" narrowing is not modelled.
# The lexer hands ":/" over as ":" then "/", so the add rule also tests a token joined to its next;
# a bare ":" or "::" is the whole tree unless the next token continues a ":/", ":(" or ":!" spelling.
_PATHSPEC_MAGIC_RE = re.compile(r":(?:\([^)]*\)|[/!^]*:?)")
def _whole_tree_pathspec(t):
    if not t.strip(":") or _EXCLUDE_PATHSPEC_RE.match(t):
        return False  # "", ":" and "::" go to the bare-colon test, which reads the next token
    m = _PATHSPEC_MAGIC_RE.match(t)
    glob = bool(m) and "glob" in m.group(0)
    t = t[m.end():] if m else t
    parts = []
    for p in t.split("/"):
        if p == "..":
            parts = parts[:-1]  # a ".." past the start climbs out of cwd: dropped, see above
        elif p not in ("", "."):
            parts.append(p)
    # "*" matches across "/" in a pathspec, so one part of only "*" (and at most one "?") matches all;
    # under ":(glob)" "*" stops at "/" but "**/" spans dirs, so "**/*" and "**/**" match all.
    star = [("*" in p and p.replace("*", "") in ("", "?")) for p in parts]
    return not parts or (len(parts) == 1 and star[0]) or (glob and all(star) and all("**" in p for p in parts[:-1]))
# GH #308: an exclude pathspec (":!x", ":^x", ":(exclude)x", ":/!x") alone selects the whole tree
# minus x; it is narrow only when a positive pathspec sits beside it.
_EXCLUDE_PATHSPEC_RE = re.compile(r":(?:[/!^]*[!^]|\([^)]*\bexclude\b[^)]*\))")
def _exclude_only_pathspecs(toks):
    # The lexer splits an unquoted ":!x" into ":", "!", "x" and "--chmod=+x" into "--chmod=", "+", "x".
    paths, i, after_dd = [], 0, False
    while i < len(toks):
        t = toks[i]
        i += 1
        if after_dd or not t.startswith("-"):
            if t == ":" and i < len(toks) and toks[i] in ("!", "^"):
                t, i = t + toks[i], i + 1
                i += i < len(toks)  # the glued word after the marker; ponytail: ":! src" lexes alike, denied too
            paths.append(t)
        elif t == "--":
            after_dd = True
        elif t in ("--chmod", "--chmod="):
            i += 2 if i < len(toks) and toks[i] in ("+", "-") else 1
    return bool(paths) and all(_EXCLUDE_PATHSPEC_RE.match(t) for t in paths)
KNOWN_GIT_SUBS = ("push", "reset", "clean", "restore", "checkout", "switch", "branch", "stash", "commit", "add",
                  "read-tree", "checkout-index", "worktree", "reflog", "gc", "prune", "update-ref")

_DELETE_PROTECTED = ("main", "master", "develop")

# GH #750 (operator decision 2026-10-31): the Bash tool sources the user's shell snapshot, so oh-my-zsh's git
# plugin push aliases and functions are live command words. A command word from this fixed list is read as the
# git push it runs, the user's words appended; PH stands for $(git_current_branch). gpoat runs `git push origin
# --all && git push origin --tags`: only the second takes the user's words. The strict force-push allow
# (_FORCE_PUSH_OK) reads the raw text, so a forced alias push never gets it. A user's own alias is not covered.
# Review of PR #774: ggpnp pulls, then runs ggp with the same words; grename OLD NEW runs `git push origin :OLD`,
# a remote delete (_check_window builds it). The plugin's `alias g='git'` is not read: #750 stays push-only (#781).
_SHELL_PUSH_ALIASES = {
    "ggpnp": ["push", "origin"],
    "gp": ["push"], "gpd": ["push", "--dry-run"], "gpf!": ["push", "--force"],
    "gpf": ["push", "--force-with-lease", "--force-if-includes"],
    "gpsup": ["push", "--set-upstream", "origin", PH],
    "gpsupf": ["push", "--set-upstream", "origin", PH, "--force-with-lease", "--force-if-includes"],
    "gpv": ["push", "--verbose"], "gpoat": ["push", "origin", "--tags"], "gpod": ["push", "origin", "--delete"],
    "ggpush": ["push", "origin", PH], "gpu": ["push", "upstream"],
    "ggf": ["push", "--force", "origin"], "ggfl": ["push", "--force-with-lease", "origin"], "ggp": ["push", "origin"],
}

def _protected_ref(name):
    # main/master/develop as the last path part, any case: "origin/main", "refs/heads/Develop".
    return name.rstrip("/").rsplit("/", 1)[-1].lower() in _DELETE_PROTECTED

# Duplication also fires on a token still carrying raw substitution syntax
# (belt-and-braces for any path that hands over an unblanked token). Narrow
# single-token check on purpose: a bare "$" would misfire on "$PYTHON -m pytest".
def _has_raw_subst(t):
    return "`" in t or "$(" in t or "${" in t

# GH #382: the names a word in a word window may expand to. A joined word holds more text than a token
# (prose and code read as shell, `r\(x\) $(..)\. You,`), so "any name" there over-denied; each PH run
# (a blanked substitution) stands for any text and the rest must match. Raw substitution syntax is
# literal here (quoted or unparsed text); the token windows keep the broad reading of both.
_WORD_PHASE = [False]
def _candidates(word, names):
    if not (PH in word or _has_raw_subst(word)):
        return (word,)
    if not _WORD_PHASE[0]:
        return names
    parts = re.split(PH + "+", word)
    if len(parts) == 1:
        return tuple(n for n in names if n == word)
    out = []
    for n in names:
        i, end = len(parts[0]), len(n) - len(parts[-1])
        if i > end or not (n.startswith(parts[0]) and n.endswith(parts[-1])):
            continue
        for p in parts[1:-1]:
            j = n.find(p, i, end)
            if j < 0:
                break
            i = j + len(p)
        else:
            out.append(n)
    return tuple(out)

# 2026-09-21 deep-audit: a bare `NAME=value` prefix (`FOO=bar rm -rf x`) made
# argv0 "FOO=bar", so every token-dispatched deny below fell through. Returns
# the assignment's (key, value) or None; the same env-var hook bypass the -c
# branch denies is checked here too (GIT_CONFIG_PARAMETERS / GIT_CONFIG_KEY_n
# carrying core.hooksPath is exactly `-c core.hooksPath=`, via the
# environment) -- one helper for the bare prefix and the `env` wrapper below.
def _assignment(t):
    key, eq, val = t.replace(PH, "").partition("=")
    if not eq or not key.isidentifier():
        return None
    if (key == "GIT_CONFIG_PARAMETERS" or key.startswith("GIT_CONFIG_KEY_")) \
            and "core.hookspath" in val.lower():
        deny("-c core.hooksPath=<path> re-points git at a different hooks dir — same bypass as --no-verify", rule="git-hooks-path")
    return key, val

# 2026-09-20 audit: git accepts any unambiguous prefix of a long
# option ("--no-veri" for "--no-verify"); the exact-string checks
# below missed it -- live-confirmed to actually execute
# (--no-veri/--ha/--amen/--forc/--discard-ch/--del all ran for real).
# `git push --forc` is NOT exploitable this way: git itself rejects
# it as ambiguous with --force-with-lease/--force-if-includes, so
# the push check below is untouched.
def _is_flag(token, *long_forms):
    # Checked only against the SPECIFIC long form(s) given at each
    # call site below, never a global git-flag list -- so this
    # cannot itself confuse "--force" with an unrelated flag.
    # Confirmed safe against this file's own documented noisy
    # neighbors (--find-renames, --format=fuller, --force-with-lease,
    # --force-if-includes): none is a prefix of any long form checked
    # here, and a longer arg can never satisfy long_form.startswith().
    # A false-positive abbreviation only costs an extra deny/
    # confirmation -- the safe direction for this gate
    # (operating-model.md's fail-closed principle).
    #
    # compliance-audit fix-round 2, 2026-09-20: an independent
    # verifier flagged this as not "establishing unambiguity" (e.g.
    # denying `commit --no`, `branch --fo`) and claimed `--n` /
    # `--force=` slip through unguarded. Empirically re-checked
    # against real git: `--n` and every 2-3-char `=value`-suffixed
    # abbreviation tested at the time was ALWAYS rejected by git
    # itself (ambiguous, or "option takes no value") -- but that
    # check missed the shorter, plain (no `=`) 2-char-after-`--`
    # shape entirely, since the len()>3 guard below excluded it from
    # ever being checked in the first place, regardless of what git
    # would do with it.
    #
    # deep-audit fix-round 3, 2026-09-20: that gap was real and
    # live -- `git reset --h` and `git clean --f` are BOTH accepted
    # by real git as unambiguous (only one long option starts with
    # "h"/"f" for each of those subcommands) and actually executed
    # destructively, while this gate's old len()>3 guard never even
    # checked them. Fixed by lowering the guard to len()>2 (still
    # excludes a bare "--", which has no letters to be an
    # abbreviation of anything). This does NOT reintroduce the
    # already-git-rejected forms as a gap: those still fail on the
    # `long_form.startswith(token)` check itself (git's own
    # ambiguity has no bearing on that), so lowering the length
    # floor only newly catches tokens that are BOTH short and an
    # exact prefix of one specific named long form -- the same
    # narrow, call-site-scoped match this helper always made, one
    # character shorter.
    return token.startswith("--") and len(token) > 2 and any(
        lf.startswith(token) for lf in long_forms
    )

# Bundled short flags: "-qf" means -q -f. Stop scanning a cluster
# at a value-taking letter (checkout -b/-B, switch -c/-C) so
# "-bfoo" is not misread as -f hiding inside a branch name.
# `flag` is the letter looked for (default -f; commit -n, branch
# -d, add -A use the same scan).
def _bundled_flag(t, stop_chars, flag="f"):
    if not (t.startswith("-") and not t.startswith("--")):
        return False
    for ch in t[1:]:
        if ch in stop_chars:
            return False
        if ch == flag:
            return True
    return False

def _rm_forced(scan):
    # GH #563 follow-up: whether `git rm <scan>` is a real forced delete of worktree files.
    force = dry = cached = False
    skip = False
    for t in scan:
        if skip:
            skip = False
            continue
        if t in ("--", "--end-of-options"):  # git >= 2.24 reads --end-of-options as "--"
            break
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            if _is_flag(name, "--pathspec-from-file"):
                skip = "=" not in t
            elif _is_flag(name, "--no-force", "--no-dry-run", "--no-cached"):
                # A prefix shared by several (--no-) is rejected by git; read it the deny way.
                if _is_flag(name, "--no-dry-run"):
                    dry = False
                if _is_flag(name, "--no-cached"):
                    cached = False
                if _is_flag(name, "--no-force") and not _is_flag(name, "--no-dry-run", "--no-cached"):
                    force = False
            else:
                force = force or _is_flag(name, "--force")
                dry = dry or _is_flag(name, "--dry-run")
                cached = cached or _is_flag(name, "--cached")
        elif t.startswith("-") and len(t) > 1:
            force = force or "f" in t
            dry = dry or "n" in t
    return force and not dry and not cached

def _git_words(rest, ph_value=False):
    # GH #375: git's leading global flags with each glued token run (_Glued) joined into one shell
    # word, then the subcommand and its arguments unchanged; None when no flag or value was glued.
    # The same walk as the git block: a value-taking global takes the next word.
    # GH #405: a substitution blanked inside the flag's own word (-C${R}, -C$(pwd)) is one token,
    # never glued, and both walks read it empty: a bare -C takes the next word. With ph_value it
    # holds the value instead (a word-split " /repo" does this), so the next word is the subcommand;
    # None when no flag carries one. "$" stands in, as in -C$R: a kept PH would match again in the
    # appended window and append it forever.
    out, i, n, joined, hit = [], 0, len(rest), False, False
    def word():
        nonlocal i, joined
        j = i + 1
        while j < n and isinstance(rest[j], _Glued):
            j += 1
        if j - i > 1:
            joined = True
        t, i = "".join(rest[i:j]) if j - i > 1 else rest[i], j  # join once: a long glued run stays linear
        return t
    while i < n:
        start, was_joined = i, joined
        t = word()
        if not t.replace(PH, "").startswith("-"):
            # The subcommand stays as tokens and its own glue does not count: the window this
            # returns would be the same window again, appended forever.
            i, joined = start, was_joined
            break
        out.append(t)
        st = t.replace(PH, "")
        if st in GIT_VALUE_GLOBALS:
            # GH #409: a substitution may also come before the flag letters (${E}-C${R}); the word
            # holds a value when one comes last.
            if ph_value and t.endswith(PH):
                out[-1], hit = st + "$", True
            elif i < n:
                out.append(word())
    return out + rest[i:] if (hit if ph_value else joined) else None

# GH #562: `git config` on core.hooksPath: a read (get, list, the key alone) and the one documented write,
# `core.hooksPath git-hooks` with no value-pattern, are allowed. The word git-hooks anywhere else (a
# value-pattern, a --comment) allowed `git config core.hooksPath /dev/null git-hooks`, which replaces the
# git-hooks value with /dev/null.
_GIT_CONFIG_VALUE_OPTS = ("-f", "--file", "--blob", "--type", "--comment", "--default", "--value")
_GIT_CONFIG_READ_OPTS = ("--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l", "--list")
_GIT_CONFIG_EDIT_OPTS = ("--unset", "--unset-all", "--rename-section", "--remove-section", "-e", "--edit")
def _hooks_path_ok(scan):
    pos, opts, i = [], [], 0
    while i < len(scan):
        t = scan[i]
        if t in _GIT_CONFIG_VALUE_OPTS:
            i += 2
            continue
        (opts if t.startswith("-") else pos).append(t.split("=", 1)[0] if t.startswith("--") else t)
        i += 1
    if any(t in _GIT_CONFIG_EDIT_OPTS for t in opts) or pos[:1] in (["unset"], ["rename-section"], ["remove-section"], ["edit"]):
        return False
    if pos[:1] in (["get"], ["list"]) or any(t in _GIT_CONFIG_READ_OPTS for t in opts):
        return True
    pos = pos[1:] if pos[:1] == ["set"] else pos
    return len(pos) == 1 or (len(pos) == 2 and pos[1] == "git-hooks" and not any(t == "--value" for t in opts))

def _drops_core_section(words):
    # GH #562: `git config [--]remove-section core` and `[--]rename-section core X` (or X core) drop or
    # rewrite core.hooksPath without naming it. Section names ignore case; git takes a unique prefix
    # of a long option (`--rem`); a name built at run time (a $ or a blanked substitution) may be core
    # when the literal text before it can still become core (`co$X`, not `x$Y`).
    pos, mode, i = [], False, 0
    while i < len(words):
        t = words[i].replace(PH, "")
        if t in _GIT_CONFIG_VALUE_OPTS:
            i += 2
            continue
        if t.startswith("-"):
            mode = mode or _is_flag(t, "--remove-section", "--rename-section")
        else:
            pos.append(words[i])
        i += 1
    if pos and pos[0].replace(PH, "") in ("remove-section", "rename-section"):
        mode, pos = True, pos[1:]
    return mode and any(_may_be_core(w) for w in pos)

def _may_be_core(w):
    cut = min((k for k in (w.find(PH), w.find("$")) if k >= 0), default=-1)
    return w.lower() == "core" if cut < 0 else "core".startswith(w[:cut].lower())

def _sets_hooks_path(w):
    # Does a `-c KEY=VAL` / `-cKEY=VAL` / `--config-env KEY=VAR` / `--config-env=KEY=VAR` word in
    # window w set core.hooksPath (key case-insensitive)? Any value: an empty one (`-c core.hooksPath=`)
    # unwires every hook (git 2.43, live-checked); a bare `-c core.hooksPath` (no "=") is a git error.
    for idx, t in enumerate(w):
        t_pf = t.replace(PH, "")
        if t_pf == "-c" and idx + 1 < len(w):
            kv = w[idx + 1]
        elif t_pf.startswith("-c"):
            kv = t_pf[2:]
        # --config-env=KEY=VAR / --config-env KEY=VAR: git reads the
        # value from env var VAR, same effect as -c (2026-09-21 audit).
        elif t_pf == "--config-env" and idx + 1 < len(w):
            kv = w[idx + 1]
        elif t_pf.startswith("--config-env="):
            kv = t_pf[len("--config-env="):]
        else:
            continue
        key, eq, _ = kv.partition("=")
        if key.lower() == "core.hookspath" and eq:
            return True
    return False

# GH #561: config a git run is given re-enables a denied action without its flag: an alias runs any
# subcommand or shell line, remote.<r>.mirror is push --mirror, a "+" remote.<r>.push refspec is a forced
# push, clean.requireForce=false is clean -f, and gc's expiry keys at now are reflog expire + prune.
# Read from `-c KEY=VAL` (and a `git config KEY VALUE` write of the same keys, see _git_config_write).
_GIT_FALSE = ("false", "no", "off", "0", "")
class _GitCfgUnseen(str):
    # A config value the gate cannot see (PR #571 review): --config-env's env var, or a value built at
    # run time ($X, $(...)). Checks read it as the dangerous value, as an unknown value is elsewhere.
    pass
_GIT_CFG_UNSEEN = _GitCfgUnseen("<a value built at run time>")

def _git_cfg_value(raw):
    # The value a config word holds, or _GIT_CFG_UNSEEN when bash builds it at run time: a blanked
    # $(...)/backtick (PH) anywhere, or a $ parameter as its first word (the verb of an alias).
    if PH in raw:
        return _GIT_CFG_UNSEEN
    first = raw.lstrip("!").split(" ", 1)[0]
    return _GIT_CFG_UNSEEN if first.startswith("$") else raw

def _git_cfg_pairs(globs):
    """(lowercased key, value) of each config pair in git's global flags, in command-line order.

    Forms: `-c KEY=VAL`, `-cKEY=VAL`, a bare `-c KEY` (git reads it as KEY=true), and
    `--config-env KEY=ENVVAR` / `--config-env=KEY=ENVVAR`, whose value is _GIT_CFG_UNSEEN (the gate
    never sees the env var). A value built at run time is _GIT_CFG_UNSEEN too (_git_cfg_value).
    One pass over globs: callers must stay linear in it (PR #571 review: a per-pair rescan of the
    arguments took 9.3 s on 80 KB, past the 8 s hook timeout, which allows).
    """
    out = []
    for idx, t in enumerate(globs):
        t_pf = t.replace(PH, "")
        env = t_pf == "--config-env" or t_pf.startswith("--config-env=")
        if t_pf in ("-c", "--config-env"):
            kv = globs[idx + 1] if idx + 1 < len(globs) else None
        elif t_pf.startswith("--config-env="):
            kv = t[t.index("=") + 1:]
        elif t_pf.startswith("-c"):
            kv = t[t.index("c") + 1:]
        else:
            continue
        if not kv:
            continue
        key, eq, val = kv.partition("=")
        key = key.replace(PH, "").lower()
        out.append((key, _GIT_CFG_UNSEEN if env else _git_cfg_value(val) if eq else "true"))
    return out

def _git_cfg_risk(key, val, sub):
    # The rule a config pair breaks for subcommand sub (None: any later run), or None.
    # An unseen value takes the dangerous reading of every key.
    unseen = val is _GIT_CFG_UNSEEN
    now = unseen or val.lower() in ("now", "all", "0")
    if key.startswith("remote.") and key.endswith(".mirror") and (unseen or val.lower() not in _GIT_FALSE) and sub in ("push", None):
        return "git-push-mirror"
    if key.startswith("remote.") and key.endswith(".push") and (unseen or val.startswith("+")) and sub in ("push", None):
        return None if _FORCE_PUSH_OK else "git-push-force"
    if key == "clean.requireforce" and (unseen or val.lower() in _GIT_FALSE) and sub in ("clean", None):
        return "git-clean-force"
    if key in ("gc.pruneexpire", "gc.reflogexpire", "gc.reflogexpireunreachable") and now and sub in ("gc", None):
        return "git-reflog-prune"
    return None

def _git_alias_check(val, args, how):
    # GH #561: an alias body runs as `git <body> <args>`, or a "!" body as a shell line. A body built
    # at run time is unseen, so it is denied like --config-env's (git's own reading of a run-time verb,
    # `git "$(...)" ...`, also takes the denying reading).
    if val is _GIT_CFG_UNSEEN:
        deny(how + " runs " + _GIT_CFG_UNSEEN + " — the gate cannot see what it runs; confirm with user first",
             rule="git-alias-unseen")
    elif val and val != "true":
        _GIT_ALIAS_SCANNED[0] = True
        _scan_body((val[1:] if val.startswith("!") else "git " + val) + (" " + " ".join(args) if args else ""))

# The second operand of a read, list, edit or remove action is a value-pattern, not a value written.
# The option lists are GH #562's (_hooks_path_ok), shared rather than repeated.
_GIT_CONFIG_NO_WRITE_OPTS = _GIT_CONFIG_READ_OPTS + _GIT_CONFIG_EDIT_OPTS + ("--get-color", "--get-colorbool")
_GIT_CONFIG_NO_WRITE_SUBS = ("get", "list", "unset", "remove-section", "rename-section", "edit")
def _git_config_write(words):
    """(key, value) a `git config [set|--add|--replace-all] KEY VALUE` writes, or None.

    words are the raw words after `config` (args, not scan: scan drops an empty word, and an empty
    boolean is false, so `clean.requireForce ""` is a write), a blanked substitution (PH) in place:
    a value built at run time comes back as _GIT_CFG_UNSEEN. git config stops reading options at its
    first plain word (round 2 review, checked on git 2.43), so a read, edit or unset option counts
    only before it: `--unset KEY +HEAD:main` names a value-pattern to remove and writes nothing, but
    `KEY VALUE --unset` writes. None for a read, a list, an edit, an unset or a key with no dot.
    Value-taking options (_GIT_CONFIG_VALUE_OPTS, shared with _hooks_path_ok) are skipped with
    their value.
    """
    n = len(words)
    def options(i):
        # Index of the first plain word from i, and whether a no-write option came before it.
        no_write = False
        while i < n:
            t = words[i].replace(PH, "")
            if t == "--":
                return i + 1, no_write
            if not t.startswith("-") or t == "-":
                break
            if t in _GIT_CONFIG_VALUE_OPTS:
                i += 2
                continue
            no_write = no_write or t.split("=", 1)[0] in _GIT_CONFIG_NO_WRITE_OPTS
            i += 1
        return i, no_write
    i, no_write = options(0)
    if no_write or (i < n and words[i].replace(PH, "") in _GIT_CONFIG_NO_WRITE_SUBS):
        return None
    if i < n and words[i].replace(PH, "") == "set":
        i, no_write = options(i + 1)
        if no_write:
            return None
    pos = words[i:]
    if len(pos) < 2 or "." not in pos[0]:
        return None
    return pos[0].replace(PH, ""), _git_cfg_value(pos[1])

def _git_clean_dry_run(words):
    # Does `git clean <words>` run as a dry run (-n, --dry-run) or ask first (-i, --interactive)?
    # Read in order, as git does (round 2 review): -e/--exclude takes the next word (or the rest of
    # its cluster) as a value, and `--` ends the options, so `-e -n` and `-- -n` are not a dry run.
    # The last of -n/--dry-run and --no-dry-run wins (round 3 review: `-n --no-dry-run` deletes).
    dry = inter = False
    i = 0
    while i < len(words):
        t = words[i].replace(PH, "")
        i += 1
        if t == "--":
            break
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            if _is_flag(name, "--exclude"):
                i += 0 if "=" in t else 1
            elif _is_flag(name, "--dry-run"):
                dry = True
            elif _is_flag(name, "--no-dry-run"):
                dry = False
            elif _is_flag(name, "--interactive"):
                inter = True
            elif _is_flag(name, "--no-interactive"):
                inter = False
        elif t.startswith("-"):
            for k, ch in enumerate(t[1:]):
                if ch == "e":
                    i += 1 if k == len(t) - 2 else 0
                    break
                if ch == "n":
                    dry = True
                elif ch == "i":
                    inter = True
    return dry or inter

_GIT_ALIAS_DEPTH = 10
def _git_alias_chain(aliases, verb):
    """Follow -c aliases from the typed verb: (steps, how, body).

    steps is [(verb, words)], the typed verb with no words first, then each non-! expansion (its
    extra words go before the user's). git always runs a built-in and ignores an alias of the same
    name, and the gate does not know every built-in, so callers check EVERY step and any deny wins
    (round 3 review: alias.push=status hid a mirror push). how names the last alias used (None:
    none). body is what ends the chain when it is not a plain verb: a ! shell line, or
    _GIT_CFG_UNSEEN for a value built at run time or a chain still going after _GIT_ALIAS_DEPTH
    steps (git follows it further). A loop stops at the first repeat (git errors and runs nothing);
    each alias is split at most once, so the walk stays linear.
    """
    steps, words, seen, how = [(verb, [])], [], set(), None
    for _ in range(_GIT_ALIAS_DEPTH + 1):
        name = verb.replace(PH, "").lower()
        val = aliases.get(name)
        if val is None or val == "true" or not val.strip() or name in seen:
            return steps, how, None
        if len(seen) == _GIT_ALIAS_DEPTH:
            return steps, how, _GIT_CFG_UNSEEN
        seen.add(name)
        how = "git -c alias." + name
        if val is _GIT_CFG_UNSEEN or val.startswith("!"):
            return steps, how, val
        try:
            exp = shlex.split(val)
        except ValueError:
            exp = val.split()
        if not exp:
            return steps, how, None
        verb, words = exp[0], exp[1:] + words
        steps.append((verb, words))
    return steps, how, None

# GH #336: chmod making files world-writable (777 / a+rwx) recursively or on / or ~.
# The tokenizer splits `+` out of a word (`a+rwx` is "a", "+", "rwx"), so the mode is read on the
# joined words. 777 means u, g and o each get r, w and x: in any letter order, with X (execute on
# directories, which a recursive chmod reaches), and across a clause list (u+rwx,g+rwx,o+rwx). A clause
# with no who letter is masked by umask, and a `-` clause is ignored (the deny direction). Ignoring `-` is
# deliberate: the gate reads only the command text, so ordering the clauses (a later - taking bits away) let
# a $V, a $(..) or a copy clause give them back; three validator rounds each found a new such shape
# (2026-10-06), so `chmod a+rwx,o-w` stays denied, an over-deny by design.
_CHMOD_CLAUSE = r"(?:0*[0-7]?777|[ugoa]* ?[-+=] ?[rwxXst]*(?: ?[-+=] ?[rwxXst]*)*)"
_CHMOD_WORLD_RE = re.compile(r"(?:^| )(" + _CHMOD_CLAUSE + r"(?: ?, ?" + _CHMOD_CLAUSE + r")*)(?: |$)")
_CHMOD_SYM_RE = re.compile(r"([ugoa]*)((?:[-+=][rwxXst]*)+)")
_CHMOD_OP_RE = re.compile(r"([-+=])([rwxXst]*)")
def _chmod_world_mode(s):
    got = {"u": "", "g": "", "o": ""}
    for c in s.split(","):
        if re.fullmatch(r"0*[0-7]?777", c):
            return True
        m = _CHMOD_SYM_RE.fullmatch(c)
        if not (m and m.group(1)):
            continue
        perms = "".join(p for op, p in _CHMOD_OP_RE.findall(m.group(2)) if op != "-")
        for w in ("ugo" if "a" in m.group(1) else m.group(1)):
            got[w] += perms
    return all("r" in p and "w" in p and ("x" in p or "X" in p) for p in got.values())
_ROOT_OR_HOME = ("/", "/*", "/.", "~", "~/", "~/*", "~/.")
# GH #587: `$HOME` / `"$HOME"` (shlex cuts it into "$", "HOME", so it is read on the joined words), and
# a path that normalises to / or to this machine's home (taken from the environment at run time).
# `${HOME}` (and `${HOME:-}`, `${HOME%/}`, ...) is blanked to a substitution before the rules read it,
# so a placeholder target is matched against the raw text of a chmod's own arguments (the text after
# `chmod` up to its statement's end), never against another statement's `echo ${HOME}`.
_HOME_BRACED_RAW_RE = re.compile(r"(?<![\w$])[\"']{0,2}\$\{HOME(?:[:%#/^,][^}]{0,40})?\}(?:/[./*]*)?[\"']{0,2}(?=[\s;&|)<>]|$)")
_CHMOD_ARGS_RAW_RE = re.compile(r"(?<![\w.-])g?chmod(?![\w.-])([^;&|\n]*)")
def _root_or_home_word(rest):
    words, cur = [], []
    for t in rest:
        if cur and not isinstance(t, _Glued):
            words.append("".join(cur))
            cur = []
        cur.append(t)
    if cur:
        words.append("".join(cur))
    home = os.path.normpath(os.path.expanduser("~"))
    for w in words:
        if w in _ROOT_OR_HOME:
            return True
        if PH in w and w.strip(PH + "/.*") == "" and any(
                _HOME_BRACED_RAW_RE.search(m.group(1))
                for m in _CHMOD_ARGS_RAW_RE.finditer(cmd.replace("\\\n", " "))):  # `\`-newline joins a line
            return True
        # `$HOME/./`, `~/..`: the home prefix is read as the home dir, then the path is normalised.
        for pre in ("$HOME", "~"):
            if w == pre or w.startswith(pre + "/"):
                w = home + w[len(pre):]
                break
        base = w[:-2] if w.endswith("/*") else w
        if base.startswith("/") and PH not in base and os.path.normpath(base) in ("/", "//", home):
            return True
    return False

# GH #595: the virtualenv activate scripts source-file lets through: a word whose last two path parts are bin and
# activate, activate.fish or activate.csh (the decision on the issue; a bare `source activate` still asks).
_VENV_ACTIVATE_RE = re.compile(r"(?:^|/)bin/activate(?:\.fish|\.csh)?\Z")

def _venv_activate(rest):
    # Glued runs joined, so an unquoted `$VENV/bin/activate` is one word; a leading `--` is source's own.
    # GH #768: a first token glued to argv0 (`source$X/bin/activate`) is one shell word with it, not a path.
    if isinstance(rest[0], _Glued):
        return False
    words = _shell_words(rest)
    if words[:1] == ["--"]:
        words = words[1:]
    elif words[0].startswith("-"):  # an option word (`--$X/bin/activate`): sources only when $X splits
        return False
    return len(words) == 1 and bool(_VENV_ACTIVATE_RE.search(words[0]))

# trash (trash-put, gio trash) of a whole tree: /, ~, ., .., *, an empty word, $HOME, $PWD, $(pwd) or the home
# path. Any other variable stays allowed (trash is recoverable; the docs advise "${X:?}"). A ${HOME} or $(pwd)
# word is blanked to a placeholder, so it is matched on trash's own raw arguments, as chmod's ${HOME} is.
_TRASH_TREE_WORDS = ("/", "~", ".", "..", "../..", "*", ".*", "", "$HOME", "$PWD")
_TRASH_ARGS_RAW_RE = re.compile(r"(?<![\w.-])(?:trash(?:-put)?|gio\s+trash)(?![\w.-])([^;&|\n]*)")
_PWD_SUBST_WORDS = ("$(pwd)", "`pwd`")
def _trash_norm(w, dotstar=True):
    # The tree itself or everything in it: quotes removed, then each trailing /, /. or /* (~/*, "$HOME"/, ../), and
    # /.* (GH #741: every dotfile in it) unless dotstar is off.
    w = w.replace('"', "").replace("'", "")
    ends = ("/", "/.", "/*", "/.*") if dotstar else ("/", "/.", "/*")
    while w.endswith(ends) and w != "/":
        w = w[:-1] if w.endswith("/") else w[:-3] if w.endswith("/.*") else w[:-2]
    return w

def _trash_whole_tree(rest):
    words, cur = [], []
    for t in rest:
        if cur and not isinstance(t, _Glued):
            words.append("".join(cur))
            cur = []
        cur.append(t)
    if cur:
        words.append("".join(cur))
    home, opts = os.path.normpath(os.path.expanduser("~")), True
    for w in words:
        if opts and w.startswith("-"):
            opts = w != "--"
            continue
        w0, w = w, _trash_norm(w)
        if w in _TRASH_TREE_WORDS or (w.startswith("/") and PH not in w and os.path.normpath(w) in ("/", home)):
            return True
        # A placeholder word: each raw operand of trash, normalized the same way, is read for $(pwd) / `pwd`. Only a word
        # that is bare without the /.* strip too ($(x)/.* is not, as on develop): the re-read costs the whole command per
        # word, so 3100 such words took 6 s (GH #741 review 4).
        if PH in w and w.strip(PH) == "" and _trash_norm(w0, False).strip(PH) == "" and any(
                any(_trash_norm(r, False) in _PWD_SUBST_WORDS for r in m.group(1).split())
                                                or _HOME_BRACED_RAW_RE.search(m.group(1))
                                                for m in _TRASH_ARGS_RAW_RE.finditer(cmd.replace("\\\n", " "))):
            return True
    return False

def _chmod_world(rest, recursive=False):
    # recursive: the mode reaches every file anyway (a find -exec action, GH #587).
    toks = [t.replace(PH, "") for t in rest]
    # GH #405: only the mode word is read (the first word that is not an option; an empty
    # substitution before it joins as a leading blank, which the regex allows), so a file named
    # 777 or a+rwx is not a mode.
    k = next((j for j, t in enumerate(toks) if not t.startswith("-")), len(toks))
    m = _CHMOD_WORLD_RE.match(" ".join(toks[k:]))
    return ((m and _chmod_world_mode(m.group(1).replace(" ", ""))) or _chmod_world_word(rest)) and (
        recursive or _root_or_home_word(rest) or any(
            t in _ROOT_OR_HOME or _is_flag(t, "--recursive")
            or (t.startswith("-") and not t.startswith("--") and "R" in t) for t in toks))

# GH #409: the mode read again on shell words (each glued token run joined, as _git_words does).
# A comma mode (u+s,a+rwx) is one word whose clauses are each a mode; a word that is only an
# expansion ($V, "$1") may be empty, so it is not the mode word; an option word made only of mode
# characters (-x,a+rwx) is a mode to chmod wherever it stands. A deny in either reading wins.
_CHMOD_DASH_MODE_RE = re.compile(r"-[-+=,0-7rwxXstugoa]+")
_EXPANSION_ONLY_RE = re.compile(r"(?:" + PH + r"|\$(?:\w+|[@*#?$!-]))+")
def _chmod_world_word(rest):
    runs = []
    for t in rest:
        if runs and isinstance(t, _Glued):
            runs[-1].append(t)
        else:
            runs.append([t])
    seen = False  # the mode word was read; GNU chmod still takes a mode option after it
    for r in runs:
        w = "".join(r)
        s = w.replace(PH, "")
        mode = not seen and not s.startswith("-")
        if mode and _EXPANSION_ONLY_RE.fullmatch(w):
            continue
        if (mode or _CHMOD_DASH_MODE_RE.fullmatch(s)) and _chmod_world_mode(s):
            return True
        seen = seen or mode
    return False

# GH #336: a program known only at run time -- a `$NAME` argv0 with no `NAME=` anywhere in the
# command (the var-verb view below reads a visible one back) -- or a sourced file.
_VAR_NAME_RE = re.compile(r"[A-Za-z_]\w*")
# GH #593: an assignment prefixed to a command (`X=rm true; $X build`) lives in that command's
# environment alone. A name counts as assigned unless every `NAME=` is such a prefix: a chain of
# `NAME=value` words the scan reads whole, then blanks, then a plain word. A value it cannot read
# (`$(...)`, `${...}`, an array) or a chain ended by anything else (a separator, a redirection, a line
# continuation) counts as assigned, as before. A prefix to a program that runs a body (`CMD=ls bash -c
# '$CMD x'`) feeds that body, so it counts too. One non-overlapping pass, so the cost stays linear.
_ASSIGN_WORD_RE = re.compile(r"""(?<![\w$=])([A-Za-z_]\w*)\+?=(?:'[^']*'|"(?:[^"\\]|\\.)*"|[^\s;&|()<>'"\\`{]|\\.)*""")
_BLANKS_RE = re.compile(r"[ \t]*")
_PREFIX_NEXT_RE = re.compile(r"""[ \t]+(?!\d*[<>])([\w./~"'$-][^\s;&|()<>]*)""")
_PREFIX_BODY_RUNNERS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "hush", "env", "xargs", "eval", "exec", "sudo", "doas", "su",
                        "nohup", "setsid", "stdbuf", "timeout", "nice", "ionice", "taskset", "chroot", "unshare",
                        "nsenter", "chpst", "setuidgid",
                        "script", "command", "builtin", "time", "find", "watch", "flock", "parallel", "npx",
                        "python", "python3", "perl", "ruby", "node"}
_DECLARE_TAIL_RE = re.compile(r"(?:^|[\s;&|(){])(?:export|readonly|declare|typeset|local)(?:[ \t]+-\w+)*[ \t]+$")
_ASSIGNED_NAMES = set(re.findall(r"(?<![\w$])([A-Za-z_]\w*)\+?=", cmd))
_standalone, _prefixed, _chain = set(), set(), []
for _m in _ASSIGN_WORD_RE.finditer(cmd):
    _chain.append(_m)
    _gap = _BLANKS_RE.match(cmd, _m.end()).end()
    _nx = _ASSIGN_WORD_RE.match(cmd, _gap) if _gap > _m.end() else None
    if _nx:
        continue  # the chain goes on; finditer reaches the next word itself
    _nw = _PREFIX_NEXT_RE.match(cmd, _m.end())
    _prefix = bool(_nw) and not _DECLARE_TAIL_RE.search(cmd[max(0, _chain[0].start() - 80):_chain[0].start()])
    if _prefix and basename(_nw.group(1).strip("\"'")) in _PREFIX_BODY_RUNNERS:
        _prefix = False
    (_prefixed if _prefix else _standalone).update(c.group(1) for c in _chain)
    _chain = []
_ASSIGNED_NAMES -= _prefixed - _standalone

def _opaque_var(argv0, rest):
    # shlex splits an unquoted `$X` into "$" and "X"; a quoted "$X" stays one word.
    name = rest[0] if argv0 == "$" and rest else argv0[1:] if argv0.startswith("$") else ""
    return bool(_VAR_NAME_RE.fullmatch(name)) and name not in _ASSIGNED_NAMES

# 2026-10-23: `gh api` write detection, so settings.json can drop its blanket Bash(gh api *) ask and
# reads stop prompting. gh follows pflag: a value-taking short flag takes the rest of its cluster
# (-XPUT, -iXPUT, -X=PUT) or the next word, and the last -X/--method wins. With no method gh sends
# GET, or POST once a field or --input is given. graphql is always a POST, so it is judged by its
# query text instead; a query read from a file is unseen and counts as a write.
_GH_API_SHORT_VALUE = set("XfFHpqt")
_GH_API_LONG_VALUE = {"--method", "--field", "--raw-field", "--header", "--preview", "--jq",
                      "--template", "--input", "--hostname", "--cache"}
# T2 writes (CLAUDE.md Risk tiers): comments and labels on one issue or PR, which a follow-up undoes.
_GH_API_T2_RE = re.compile(r"/?repos/[^/]+/[^/]+/(issues/\d+/(comments|labels)|pulls/\d+/comments(/\d+/replies)?)")

def _gh_api_write(args):
    method, fields, has_input, endpoint = None, [], False, None
    i = 0
    while i < len(args):
        t = args[i]
        if t.startswith("--"):
            name, eq, val = t.partition("=")
            if name in _GH_API_LONG_VALUE:
                if not eq:
                    i += 1
                    val = args[i] if i < len(args) else ""
                if name == "--method":
                    method = val
                elif name in ("--field", "--raw-field"):
                    fields.append(val)
                elif name == "--input":
                    has_input = True
                elif name == "--header" and "method-override" in val.lower():
                    has_input = True
        elif t.startswith("-") and len(t) > 1:
            for j, ch in enumerate(t[1:], 1):
                if ch in _GH_API_SHORT_VALUE:
                    val = t[j + 1:]
                    if val.startswith("="):
                        val = val[1:]
                    elif not val:
                        i += 1
                        val = args[i] if i < len(args) else ""
                    if ch == "X":
                        method = val
                    elif ch in "fF":
                        fields.append(val)
                    elif ch == "H" and "method-override" in val.lower():
                        has_input = True  # an override header turns a GET into a write
                    break
        elif endpoint is None:
            endpoint = t
        i += 1
    if endpoint == "graphql":
        # A read is a query the gate can see: text starting with "query" or "{". A $(...) or variable
        # arrives empty (its placeholder is stripped), and a file (@path) is unseen: both count as writes.
        # Leading # comment lines are ignored tokens in GraphQL, so the operation keyword follows them.
        queries = [re.sub(r"^(?:\s|#[^\n]*\n)*", "", f.split("=", 1)[1]) for f in fields
                   if f.split("=", 1)[0] == "query" and "=" in f]
        # An alias named mutation (`mutation: login`, a # comment line allowed before the colon) is a read.
        return has_input or not queries or any(
            not q.lower().startswith(("query", "{")) or re.search(r"\bmutation\b(?!(?:\s|#[^\n]*\n)*:)", q)
            for q in queries)
    if method is not None:
        write = method.upper() not in ("GET", "HEAD")
    else:
        write = bool(fields) or has_input
    return write and not (method in (None, "POST", "post") and endpoint and _GH_API_T2_RE.fullmatch(endpoint))

# Built-in gh subcommands and help topics (gh 2.x, `gh --help`). Anything else is an alias or an
# extension, either of which can run `gh api` out of sight.
_GH_BUILTINS = {"accessibility", "actions", "agent-task", "alias", "api", "attestation", "auth", "browse",
                "cache", "codespace", "completion", "config", "copilot", "discussion", "environment",
                "exit-codes", "extension", "formatting", "gist", "gpg-key", "help", "issue", "label",
                "licenses", "mintty", "org", "pr", "preview", "project", "reference", "release", "repo",
                "ruleset", "run", "search", "secret", "skill", "ssh-key", "status", "telemetry",
                "variable", "version", "workflow"}

# T3/T4 writes gh runs without `gh api` (CLAUDE.md Risk tiers): a revert can't undo them, they add a credential
# or third-party code, or they start CI. Keyed by group; "repo deploy-key" is a group of its own.
_GH_BUILTIN_WRITES = {
    "repo": {"delete", "archive", "unarchive", "rename", "edit"},
    "repo deploy-key": {"add", "delete"},
    "secret": {"set", "delete", "remove"}, "variable": {"set", "delete", "remove"},
    "release": {"delete", "delete-asset"}, "ssh-key": {"add", "delete"}, "gpg-key": {"add", "delete"},
    "extension": {"install", "upgrade", "exec"}, "alias": {"set", "import"},
    "issue": {"delete", "transfer"}, "label": {"delete"}, "cache": {"delete"}, "codespace": {"delete"},
    "workflow": {"run", "enable", "disable"}, "run": {"cancel", "delete", "rerun"}, "project": {"delete"},
    "gist": {"delete"},  # GH #564: a deleted gist cannot be restored
}
# Verbs that are T2 by default and T3/T4 only with one flag: --clobber deletes the old asset, --force hard-resets,
# --rebase rewrites the PR's head branch on GitHub (a force-push to it; the default merge commit rewrites nothing).
_GH_BUILTIN_FORCED = {("release", "upload"): "--clobber", ("repo", "sync"): "--force", ("pr", "update-branch"): "--rebase"}
# Cobra aliases of the groups above (`gh <group> --help` lists them).
_GH_GROUP_ALIASES = {"cs": "codespace", "ext": "extension", "extensions": "extension"}

def _gh_words(scan, limit):
    # Indexes of the first positional words the way cobra finds a subcommand: "--x=v", an attached "-xV"
    # and help/version stand alone, a bare "-" is dropped, any other bare "-x" or "--flag" takes the next
    # word as its value (so `gh secret -e prod set` is `secret set`). An empty word is a stripped $(...) or
    # variable, unknown until it runs, so it is kept as a word, not skipped.
    idx, i = [], 0
    while i < len(scan) and len(idx) < limit:
        t = scan[i]
        if t == "--":
            break
        if t.startswith("-"):
            alone = t == "-" or "=" in t or t in ("-h", "--help", "--version") or (not t.startswith("--") and len(t) > 2)
            i += 1 if alone else 2
            continue
        idx.append(i)
        i += 1
    return idx

# GH #621: long flags that are boolean wherever gh defines them (the forced/write verbs' flags and their
# kin, from each verb's `gh <group> <verb> --help`), so they take no value and a -h after one is help.
# Short flags are left out: a letter means different things per verb (pr merge -r is --rebase, pr create
# -r is --reviewer), and an unlisted flag keeps taking the next word, so an unsure -h still asks.
_GH_BOOL_LONG = {"--rebase", "--clobber", "--force", "--yes", "--confirm", "--admin", "--auto", "--squash",
                 "--merge", "--delete-branch", "--draft", "--web"}

def _gh_help(scan):
    # A -h/--help that cobra reads as a flag (before "--", not a flag's value) only prints help.
    i = 0
    while i < len(scan) and scan[i] != "--":
        t = scan[i]
        if t in ("-h", "--help"):
            return True
        alone = (not t.startswith("-") or t == "-" or "=" in t or t in ("--version", *_GH_BOOL_LONG)
                 or (not t.startswith("--") and len(t) > 2))
        i += 1 if alone else 2
    return False

def _gh_group_first(scan):
    # Flags may come before the group (`gh -X DELETE api ...`) and gh still applies them, so move the group
    # to the front, under its full name, and keep every other word for the checks that read flags.
    idx = _gh_words(scan, 1)
    if not idx:
        return scan
    group = scan[idx[0]]
    return [_GH_GROUP_ALIASES.get(group, group)] + scan[:idx[0]] + scan[idx[0] + 1:]

def _gh_builtin_write(scan):
    # The write's name for the ask message ("secret set", "release upload --clobber"), or "" for none.
    group, rest = scan[0], scan[1:]
    if group == "":
        return "<a group built at run time>"
    words = [rest[i] for i in _gh_words(rest, 2)]
    if group == "repo" and words[:1] == ["deploy-key"]:
        group, words = "repo deploy-key", words[1:]
    if not words:
        return ""
    if words[0] == "" and (group in _GH_BUILTIN_WRITES or group == "pr"):
        return f"{group} <a verb built at run time>"
    flag = _GH_BUILTIN_FORCED.get((group, words[0]))
    if words[0] in _GH_BUILTIN_WRITES.get(group, ()):
        return f"{group} {words[0]}"
    flags = rest[:rest.index("--")] if "--" in rest else rest
    # pflag's false spellings (strconv.ParseBool) turn the flag off.
    if flag and any(t == flag or (t.startswith(flag + "=") and t[len(flag) + 1:] not in ("0", "f", "F", "false", "FALSE", "False"))
                    for t in flags):
        return f"{group} {words[0]} {flag}"
    return ""

# GH #560: the words of an `env -S` string when its first word is an env option (env reads on
# from them), else None (the string is the command line, scanned like a sh -c body). An unbalanced
# quote is None too, so the string still gets the body scan.
_ENV_SPLIT_MAX = 16
def _env_split_options(body):
    if not body.replace(PH, "").lstrip().startswith("-"):
        return None
    # GH #560 round 2: env ends the string at `\c` (outside single quotes) and at a word that
    # starts with `#`, then reads on from the words after the -S argument (`env -S '-i #' rm -rf x`
    # runs rm). shlex would turn `\c` into a `c` word and keep `#`, the command env never runs.
    q, k = "", 0
    while k < len(body):
        ch = body[k]
        if ch == "'" and q != '"':
            q = "" if q else "'"
        elif ch == '"' and q != "'":
            q = "" if q else '"'
        elif ch == "\\" and q != "'":
            if body[k + 1:k + 2] == "c":
                body = body[:k]
                break
            k += 1
        k += 1
    lex = shlex.shlex(body, posix=True)
    lex.whitespace_split, lex.commenters = True, ""
    try:
        words = list(lex)
    except ValueError:
        return None
    for n, word in enumerate(words):
        if word.startswith("#"):
            return words[:n]
    return words

# GH #621: GNU env's own reading of a -S string (coreutils 9.4, checked with printf): the words env
# puts back into its argv before it reads on (its options too, so `"-i" rm -rf x` runs rm), or None
# when env rejects the string (an unterminated quote, `\q`, `\c` in double quotes, a bad `${`), so
# it runs nothing. Outside quotes `\_` and space, tab, newline, CR, VT and FF end a word, and `\c`
# or a `#` that starts a word ends the string (`env -S '#x' rm -rf x` runs rm); inside double quotes
# `\_` is a space. `\t \n \v \f \r` are characters, never word breaks; `\" \' \# \$ \\` are the
# character itself. Single quotes keep everything but `\\` and `\'`. `${NAME}` stays as its text
# (env expands it; the gate cannot know the value), as develop's shlex reading kept it.
_ENV_S_ESC = {"t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
              '"': '"', "'": "'", "#": "#", "$": "$", "\\": "\\"}
_ENV_S_VAR = re.compile(r"\$\{[A-Za-z_]\w*\}")

def _env_split(body):
    words, cur, started, q, k, n = [], [], False, "", 0, len(body)
    while k < n:
        ch = body[k]
        if q == "'":
            if ch == "'":
                q = ""
            elif ch == "\\" and body[k + 1:k + 2] in ("\\", "'"):
                k += 1
                cur.append(body[k])
            else:
                cur.append(ch)
        elif ch == "\\":
            e = body[k + 1:k + 2]
            k += 1
            if e == "_" and not q:
                if started:
                    words.append("".join(cur))
                cur, started = [], False
            elif e == "_":
                cur.append(" ")
            elif e == "c" and not q:
                break
            elif e in _ENV_S_ESC:
                cur.append(_ENV_S_ESC[e])
                started = True
            else:
                return None  # `\c` in double quotes, an unknown escape, a trailing backslash
        elif ch == "$":
            m = _ENV_S_VAR.match(body, k)
            if not m:
                return None  # env takes only ${NAME}
            cur.append(m.group())
            started, k = True, m.end() - 1
        elif q == '"':
            if ch == '"':
                q = ""
            else:
                cur.append(ch)
        elif ch in " \t\n\r\v\f":
            if started:
                words.append("".join(cur))
            cur, started = [], False
        elif ch == "#" and not started:
            break
        else:
            if ch in "'\"":
                q = ch
            else:
                cur.append(ch)
            started = True
        k += 1
    else:
        if q:
            return None
    if started:
        words.append("".join(cur))
    return words

# GH #621: getopt_long's reading of an env long option: the exact name, else the one option the
# prefix names (`--ch` is --chdir), else None (ambiguous `--d`, or unknown: env fails, runs nothing).
_ENV_LONG = ("ignore-environment", "null", "unset", "chdir", "split-string", "block-signal", "default-signal",
             "ignore-signal", "list-signal-handling", "debug", "help", "version")

def _env_long(t):
    name = t[2:].split("=", 1)[0]
    if not name or name in _ENV_LONG:
        return name or None
    hits = [o for o in _ENV_LONG if o.startswith(name)]
    return hits[0] if len(hits) == 1 else None

def _env_develop_reading(rest, i):
    """GH #621: env's words as the gate read them before #621 (long options bare flags, only an
    option-led -S string split, by shlex), so no shape that denied then allows now. Returns the words
    from the command on, or None (no command, or a -S string scanned as a command line, which it
    scans here as it did then)."""
    splits = 0
    while i < len(rest):
        t = rest[i].replace(PH, "")
        long_name, body = t[2:].split("=", 1)[0], None
        if t.startswith("--") and len(long_name) > 0 and "split-string".startswith(long_name):
            if "=" in t:
                body, i = rest[i].split("=", 1)[1], i + 1
            elif i + 1 < len(rest):
                body, i = rest[i + 1], i + 2
            else:
                return None
            m = None
        else:
            m = re.match(r"-[^-CPSu]*([CPSu])", t)
            if m:
                attached = t[m.end():]
                if m.group(1) == "S" and (attached or i + 1 < len(rest)):
                    body = rest[i][rest[i].index("S") + 1:] if attached else rest[i + 1]
                i += 1 if attached else 2
        if body is not None:
            words = _env_split_options(body)
            splits += 1
            if words is None or splits > _ENV_SPLIT_MAX:
                _scan_body(" ".join([body] + rest[i:]))
                return None
            rest, i = words + rest[i:], 0
        elif m:
            pass
        elif t.startswith("-") or _assignment(rest[i]):
            i += 1
        else:
            return rest[i:]
    return None

# One window's checks. A function, not the loop body, so the GH #336 views below rerun it.
# xargs's short options that take a value (GNU and BSD), and its long ones that take the next word.
_XARGS_VALUE_LETTERS = "IJRSnPLdsEa"
_XARGS_VALUE_LONG = ("--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars",
                     "--process-slot-var", "--max-lines", "--replace", "--eof")

def _xargs_command(rest):
    # The index of the command xargs runs in its args: past its flags and their values. A short
    # cluster is read left to right: the first letter that takes a value takes the rest of the
    # cluster (`-d'\n'`, `-Is`), or the next word when it is the cluster's last letter (`-tJ x`).
    j = 0
    while j < len(rest) and rest[j].replace(PH, "").startswith("-"):
        t = rest[j].replace(PH, "")
        j += 1
        if t == "--":
            break
        if t.startswith("--"):
            j += t in _XARGS_VALUE_LONG and j < len(rest)
            continue
        for k, ch in enumerate(t[1:], 1):
            if ch in _XARGS_VALUE_LETTERS:
                j += k == len(t) - 1 and j < len(rest)
                break
    return j

def _past_wrapper_words(name, rest, i):
    # The index past a prefix wrapper's own words in rest[i:]: its dash words and their values,
    # env's and sudo's assignments, timeout's duration. Used inside xargs's command (F5).
    vals = set(FLAG_VALUE_WRAPPERS.get(name, ()))
    if name in ("sudo", "doas"):
        vals |= {"-u", "-g", "-C", "-p", "-D", "-h", "-r", "-t", "-U", "--user", "--group"}
    if name == "env":
        vals |= {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"}
    while i < len(rest):
        t = rest[i].replace(PH, "")
        if t.startswith("-") and len(t) > 1:
            # GH #621: env's long options by getopt_long's prefix rule (`--ch DIR`, `--un NAME`).
            long_val = name == "env" and t.startswith("--") and "=" not in t \
                and _env_long(t) in ("chdir", "unset", "split-string")
            i += 2 if t in vals or long_val else 1
        elif _assignment(rest[i]) and name in ("env", "sudo", "doas"):
            i += 1
        else:
            break
    if name in ("timeout", "gtimeout") and i < len(rest):
        i += 1  # the DURATION positional
    return i

# GH #584 (bypass hunt F6): the container tools whose exec runs a command, and each one's options
# that take the next word as a value (an attached `--user=x` or `-upostgres` is one word anyway).
_CONTAINER_TOOLS = ("docker", "podman", "docker-compose", "kubectl")
_DOCKER_GLOBAL_VALUES = {"-H", "--host", "-c", "--context", "--config", "-l", "--log-level", "--tlscacert",
                         "--tlscert", "--tlskey", "--url", "--connection", "--identity", "--root", "--runroot",
                         "--runtime", "--cgroup-manager", "--storage-driver", "--storage-opt", "--tmpdir", "--ssh",
                         "--module", "--network-cmd-path", "--events-backend", "--log-driver", "--hooks-dir"}
_DOCKER_EXEC_VALUES = {"-e", "--env", "--env-file", "-u", "--user", "-w", "--workdir", "--detach-keys",
                       "--preserve-fd", "--preserve-fds"}
_COMPOSE_GLOBAL_VALUES = {"-f", "--file", "-p", "--project-name", "--profile", "--env-file",
                          "--project-directory", "--ansi", "--parallel", "--progress"}
_COMPOSE_EXEC_VALUES = {"-e", "--env", "-u", "--user", "-w", "--workdir", "--index"}
_KUBECTL_VALUES = {"-v", "--v", "-n", "--namespace", "--context", "--cluster", "--kubeconfig", "-s", "--server", "--user",
                   "--as", "--as-group", "--request-timeout", "-c", "--container", "-f", "--filename",
                   "--pod-running-timeout"}

def _past_options(rest, i, values):
    # The index of the first word in rest[i:] that is not an option or an option's value.
    while i < len(rest):
        t = rest[i].replace(PH, "")
        if not t.startswith("-") or t in ("-", "--"):
            break
        # A short cluster whose last letter takes a value takes the next word too (`-itu postgres`).
        i += 2 if t in values or (not t.startswith("--") and "-" + t[-1] in values) else 1
    return i

def _container_exec_command(tool, rest):
    # The words of the command `tool ... exec ...` runs in a container, or None when rest is not an exec.
    def word(i):
        return rest[i].replace(PH, "") if i < len(rest) else None
    if tool == "kubectl":
        i = _past_options(rest, 0, _KUBECTL_VALUES)
        if word(i) != "exec":
            return None
        tail = rest[i + 1:]
        if "--" in tail:  # `kubectl exec POD [flags] -- CMD`
            return tail[tail.index("--") + 1:] or None
        i = _past_options(tail, 0, _KUBECTL_VALUES) + 1  # the legacy form, CMD right after POD
        return tail[_past_options(tail, i, _KUBECTL_VALUES):] or None
    if tool == "docker-compose":
        i, compose = 0, True
    else:
        i = _past_options(rest, 0, _DOCKER_GLOBAL_VALUES)
        compose = word(i) == "compose"
        if compose:
            i += 1
        elif word(i) == "container" and word(i + 1) == "exec":
            i += 1
    if compose:
        i = _past_options(rest, i, _COMPOSE_GLOBAL_VALUES)
    if word(i) != "exec":
        return None
    i = _past_options(rest, i + 1, _COMPOSE_EXEC_VALUES if compose else _DOCKER_EXEC_VALUES)
    if word(i) == "--":
        i += 1
    return rest[i + 1:] or None  # past the container or service name

def _find_word_may_be(t, *names):
    # GH #586: a find word that is, or with its substitutions expanded may be, one of names: `$(true)-exec`
    # (an empty splice), `-$(echo delete)`, `-de$(echo l)ete`. A substitution can expand to anything, so
    # its visible text must still show the leading `-`: a bare `$(cat pattern)` (a -name value) is not
    # read as an action, and `find . $(echo -delete)` stays a gap.
    if PH not in t:
        return t in names
    if not t.replace(PH, "").startswith("-"):
        return False
    pat = re.compile(".*".join(re.escape(piece) for piece in t.split(PH)), re.DOTALL)
    return any(pat.fullmatch(n) for n in names)

# GH #586: find tests whose next word is a value (a name, a path, a time), never an action.
_FIND_VALUE_TESTS = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex",
                     "-lname", "-ilname", "-newer", "-anewer", "-cnewer", "-samefile", "-type", "-xtype", "-user",
                     "-group", "-uid", "-gid", "-perm", "-size", "-mtime", "-atime", "-ctime", "-mmin", "-amin",
                     "-cmin", "-used", "-links", "-inum", "-maxdepth", "-mindepth", "-fstype", "-context",
                     "-printf", "-fprint", "-fprint0", "-fls", "-regextype", "-files0-from"}
_FIND_NEWER_XY_RE = re.compile(r"-newer[aBcm][aBcmt]")  # -newermt, -newerBt, ...: one value; -fprintf takes two

def _find_actions(rest, *names):
    # True when a word of find's `rest` that is not a test's value may be one of names. Read left to
    # right: a test's value is skipped even when it is itself a test's name (`-name -name -delete`
    # deletes the files named "-name").
    value = 0
    for t in rest:
        if value:
            value -= 1
            continue
        if _find_word_may_be(t, *names):
            return True
        u = t.replace(PH, "")
        value = 2 if u == "-fprintf" else 1 if u in _FIND_VALUE_TESTS or _FIND_NEWER_XY_RE.fullmatch(u) else 0
    return False

def _claude_words_spawn(words):
    # GH #588: True when claude given these words starts a session: a spawn flag, or (#583) a prompt word.
    return any(t.replace(PH, "").split("=", 1)[0] in _SPAWN_WINDOW_FLAGS + ("-w", "--background") for t in words) \
        or _claude_starts_session(" ".join(shlex.quote(t) for t in words), False)

def _find_action_spawns(sub):
    # GH #588: a find action running claude (past its wrappers) that starts a session; find hands it
    # each path as a word, so `-exec claude {} \;` gives claude a prompt.
    a0 = basename(sub[0]).replace(PH, "")
    i = _past_wrapper_words(a0, sub, 1) if a0 in _STEP_WRAPPERS else 0
    return i < len(sub) and basename(sub[i]).replace(PH, "") == "claude" and _claude_words_spawn(sub[i + 1:])

def _find_action_chmod_world(sub):
    # GH #587: a find action running chmod (past its wrappers) with a world-writable mode applies it to
    # every file find yields, as `chmod -R` does.
    a0 = basename(sub[0]).replace(PH, "")
    i = _past_wrapper_words(a0, sub, 1) if a0 in _STEP_WRAPPERS else 0
    return (i < len(sub) and basename(sub[i]).replace(PH, "") in ("chmod", "gchmod") and _chmod_world(sub[i + 1:], True)
            or _shell_body_runs(sub, lambda cur, k: basename(cur[k]).replace(PH, "") in ("chmod", "gchmod")
                                and _chmod_world(cur[k + 1:], True)))

def _shell_body_runs_rm(sub, depth=0):
    return _shell_body_runs(sub, lambda cur, k: basename(cur[k]).replace(PH, "") == "rm", depth)

def _shell_body_runs(sub, hit, depth=0):
    # GH #586: True when sub (a find action's command, `sh -c 'rm "$1"' _ {}`) is a shell (past its
    # wrappers) whose body runs a command `hit(words, k)` accepts (rm; chmod for GH #587) at a command
    # position: a statement's start or after `do`/`then`/`else`, past assignments, wrappers, `eval`
    # and `busybox`; a shell inside the body is read the same way, three levels deep.
    if depth > 3 or not sub:
        return False
    a0 = basename(sub[0]).replace(PH, "")
    i = _past_wrapper_words(a0, sub, 1) if a0 in _STEP_WRAPPERS else 0
    if i >= len(sub) or basename(sub[i]).replace(PH, "") not in _SHELLS:
        return False
    sh = basename(sub[i]).replace(PH, "")
    for g in _SHELL_GETOPT[sh]:
        body = _shell_body(sh, sub[i + 1:], g)
        if not body:
            continue
        for cur, _ww, _curc in _body_readings(body)[0]:
            starts = [0] + [k + 1 for k, t in enumerate(cur) if t in SHELL_KEYWORDS]
            for k in starts:
                while k < len(cur) and (cur[k] in SHELL_KEYWORDS or _assignment(cur[k])
                                        or basename(cur[k]).replace(PH, "") in ("eval",) + _BUSYBOX_NAMES
                                        or (k and cur[k] == "--" and basename(cur[k - 1]).replace(PH, "") in _BUSYBOX_NAMES)):
                    k += 1
                while k < len(cur) and basename(cur[k]).replace(PH, "") in _STEP_WRAPPERS:
                    k = _past_wrapper_words(basename(cur[k]).replace(PH, ""), cur, k + 1)
                if k < len(cur) and hit(cur, k):
                    return True
                if k < len(cur) and _shell_body_runs(cur[k:], hit, depth + 1):
                    return True
    return False

# GH #647: the words the command writes as a `gh <sub>`: past `gh` (not inside a word or path), a run of
# `-flag [value]` pairs, then the sub as far as a word character goes. A PH argv0 reads as every dangerous
# verb, gh included, so a regex search of the whole command per window was quadratic: padding of
# `sudo ${a} x;` pushed a later deny past the 8 s hook timeout. One forward pass over the words, cached.
_GH_SUBS = []
def _gh_written_subs():
    if _GH_SUBS:
        return _GH_SUBS[0]
    words = [(m.start(), m.group()) for m in re.finditer(r"\S+", cmd)]
    starts = [p for p, _ in words]
    reach = bytearray(len(words) + 2)
    for m in re.finditer(r"(?<![\w./-])gh(?=\s)", cmd):
        reach[bisect.bisect_left(starts, m.end())] = 1
    subs = set()
    for i, (_, t) in enumerate(words):
        if not reach[i]:
            continue
        lead = re.match(r"[\w-]*", t).group()
        if lead:
            subs.add(lead)
        if t.startswith("-") and len(t) > 1:  # a flag: the sub may follow it, or follow its value
            reach[i + 1] = 1
            if i + 1 < len(words) and not words[i + 1][1].startswith("-"):
                reach[i + 2] = 1
    _GH_SUBS.append(subs)
    return subs

# GH #594: `rm -- -rf` removes a file named -rf. A bare `--` ends rm's options, but a reading can show one
# bash never passes (a CR the tokenizer splits at, `<<- --` read as a redirect target, an interpreter's
# argv joined into shell words), and a stop there hides the flags after it. So the stop is trusted only
# when the whole command is plain `rm [flags] -- operands`: space or tab between words, and no quote,
# `$`, backslash, redirect, glob or separator anywhere, as for git branch -D (_BRANCH_D_PLAIN_RE).
_RM_PLAIN_DASHDASH = re.fullmatch(r"[ \t]*rm(?:[ \t]+(?:-[A-Za-z]+|--[a-z-]+))*[ \t]+--(?:[ \t]+[\w./+,:@%-]+)+[ \t]*",
                                  cmd) is not None

def _check_window(_wi, w):
    global _cur_depth
    _cur_depth = _WDEPTH.get(_wi, 0)
    _s = 0  # an index, one slice: a flood of `!` / NAME=v words must stay linear
    while _s < len(w) and (w[_s] in SHELL_KEYWORDS or _assignment(w[_s])):
        _s += 1
    w = w[_s:]
    if not w:
        return
    # GH #593: a word glued to the assignment just dropped is that assignment's value (`PATH=$PATH:/x make`
    # reads as `$` `PATH:/x`), never the program.
    _in_value = _s > 0 and isinstance(w[0], _Glued)
    argv0, rest = basename(w[0]), w[1:]
    # A window can start at `-exec` (a second -exec after an escaped `;`) or `--`
    # (xargs -I{} -- CMD splits at the `{}` operator): the command follows.
    # `find -exec true {} + -exec CMD {} +`: `{}` splits the window, so the second one starts at `+`.
    # An index, not repeated slicing: a flood of `-exec` words must stay linear.
    _k = 0
    while _k < len(rest) and argv0 in ("-exec", "-execdir", "-ok", "-okdir", "--", "+"):
        argv0, _k = basename(rest[_k]), _k + 1
    rest = rest[_k:]

    # Prefix wrappers unwrap one level per iteration so "env nice rm -rf x" or
    # "sudo rm -rf x" resolve to the real command -- everyday idioms, in scope.
    # env/sudo and FLAG_VALUE_WRAPPERS take flags+values before the wrapped
    # command; command/nohup/time/exec/setsid only take bare flags. Every flag
    # test strips PH first: a disguised
    # flag ("env $(true)-u FOO") no longer starts with a dash otherwise.
    # Shared with _SPAWN_ANCHOR_RE's wrapper allowance above (module-level
    # PREFIX_WRAPPERS) -- one definition, not two independently-typed lists;
    # a fix landing in one and not the other is exactly how the agent_id
    # truthiness bug went unnoticed at 3 of 5 real call sites across two
    # separate GH issues (2026-09-20 audit).
    # rest[o:] is the command after the wrappers read so far: an index, one slice after the loop, so a
    # long wrapper chain stays linear (each rest[i + 1:] copied the tail again).
    o, env_splits, via_run_wrapper, env_side = 0, 0, False, 0
    while o < len(rest) and (argv0 in PREFIX_WRAPPERS or argv0 in _UNWRAP_ONLY or argv0 in SHELL_KEYWORDS or argv0 in _RUN_WRAPPERS):
        if argv0 in SHELL_KEYWORDS:  # GH #213: `time ! rm -rf x`; the segment-start strip ran once
            argv0, o = basename(rest[o]), o + 1
        elif argv0 == "env":
            # GH #560: -S STRING / --split-string=STRING splits STRING into the command and its first
            # words, so it is a command line like a `sh -c` body (any words after it are appended).
            # -C (chdir) and BSD -P (path) take a value like -u.
            # A short cluster reads like getopt (GH #560 review: `env -iS 'rm -rf x'` ran the string):
            # the first value letter takes the rest of the cluster, or the next word when that is
            # empty (`-iu FOO`). getopt_long also takes an unambiguous prefix (`--split=`); `--s`
            # is the shortest, as no other env long option starts with s.
            # GH #560 regression after #570: env keeps reading ITS OWN options from the split words
            # (`env -S -i rm -rf x` and `env -S '-u FOO rm -rf x'` run rm), so a string whose first
            # word is an option is split back into this loop, not scanned as a command line.
            # _ENV_SPLIT_MAX bounds the re-splits: each one copies the tail, and a flood must stay
            # linear; past it the gate denies, like the sh -c depth limit.
            # GH #560 round 3: -S splitting has more corners than this models (a quoted or escaped
            # `#`, `\_`, a quote inside a comment, an empty nested -S, `--unset NAME`), so an env
            # with -S is ALSO read the way the gate read it before #570 (-S a bare flag, `-u` takes
            # a value), as one more window at this depth: either reading denies, so no shape that
            # denied before #570 allows now. _count_handover bounds a chain of them (each copies the tail).
            # GH #621: --chdir and --unset (and their unambiguous prefixes, `--ch`, `--un`) take the next
            # word, so the command is the word after it; that reading also gets the pre-#570 window, which
            # reads them as bare flags. Every -S string is split the way GNU env splits it (_env_split) and
            # its words go back into this loop, option-led or not (`"-i" rm`, `rm\_-rf\_x`, `#x` then the
            # real arguments); a string that is not option-led on its raw text is also scanned as a command
            # line, as before.
            i, body, pre_rest, pre_o, split_seen = o, None, rest, o, False
            while i < len(rest):
                t = rest[i].replace(PH, "")
                long_name = _env_long(t) if t.startswith("--") else None
                if long_name in ("chdir", "unset") and "=" not in t:
                    split_seen = True
                    i += 2
                    continue
                if long_name == "split-string":
                    if "=" in t:
                        body, i = rest[i].split("=", 1)[1], i + 1
                    elif i + 1 < len(rest):
                        body, i = rest[i + 1], i + 2
                    else:
                        break
                    m = None
                else:
                    m = re.match(r"-[^-CPSu]*([CPSu])", t)
                    if m:
                        attached = t[m.end():]
                        if m.group(1) == "S" and (attached or i + 1 < len(rest)):
                            body = rest[i][rest[i].index("S") + 1:] if attached else rest[i + 1]
                        i += 1 if attached else 2
                if body is not None:
                    split_seen = True
                    old = _env_split_options(body)
                    words = _env_split(body)
                    if words is None:
                        words = old
                    if words is None:
                        break
                    env_splits += 1
                    if env_splits > _ENV_SPLIT_MAX:
                        deny("env -S strings, more than %d deep - confirm with user first" % _ENV_SPLIT_MAX)
                        break
                    if old is None:
                        _scan_body(" ".join([body] + rest[i:]))
                    rest, i, body = words + rest[i:], 0, None
                elif m:
                    pass
                elif t.startswith("-"):
                    i += 1
                elif _assignment(rest[i]):
                    i += 1
                else:
                    break
            if split_seen:
                if _wi in _ENV_PRE570_WINDOWS or env_side:  # only a chain of them copies the tail again and again
                    _count_handover("env -S / --chdir / --unset")
                env_side += 1
                # GH #621: and the reading before #621, when it finds another command.
                side = _env_develop_reading(pre_rest, pre_o)
                if side and (body is not None or side != rest[i:]):
                    _WDEPTH[len(windows)] = _cur_depth
                    _ENV_PRE570_WINDOWS.add(len(windows))
                    windows.append(side)
                j = pre_o
                while j < len(pre_rest):
                    t = pre_rest[j].replace(PH, "")
                    if t == "-u" and j + 1 < len(pre_rest):
                        j += 2
                    elif t.startswith("-") or _assignment(pre_rest[j]):
                        j += 1
                    else:
                        break
                if j < len(pre_rest):
                    _WDEPTH[len(windows)] = _cur_depth
                    _ENV_PRE570_WINDOWS.add(len(windows))
                    windows.append(pre_rest[j:])
            if body is not None:
                _scan_body(" ".join([body] + rest[i:]))
                o = len(rest)
                break
            if i >= len(rest):
                break
            argv0, o = basename(rest[i]), i + 1
        elif argv0 in FLAG_VALUE_WRAPPERS:
            i = o
            while i < len(rest) and rest[i].replace(PH, "").startswith("-"):
                t = rest[i].replace(PH, "")
                i += 1
                # exec's bundled `-la NAME`: the cluster's FIRST `a` is its last char, so the
                # name is the next token. `-alpha` / `-aa` carry the name attached.
                bundled = argv0 == "exec" and t.startswith("-") and not t.startswith("--") \
                    and t.find("a", 1) == len(t) - 1
                if (t in FLAG_VALUE_WRAPPERS[argv0] or bundled) and i < len(rest):
                    i += 1
            if argv0 in ("timeout", "gtimeout"):
                i += 1  # the DURATION positional
            if i >= len(rest):
                break
            argv0, o = basename(rest[i]), i + 1
        elif argv0 in ("sudo", "doas"):  # GH #290: doas takes -u/-C values and has no long options
            # sudo -u/-g take a value: space-joined, "="-joined, attached ("-ualice"),
            # or bundled with getopt semantics ("-nu alice": alice is the value;
            # "-un alice": "n" is the value, alice is the command). -p -C -R -T -U
            # are a non-goal.
            LONG_VALUE_FLAGS = {"--user", "--group"} if argv0 == "sudo" else set()
            _VALUE_LETTERS = "ug" if argv0 == "sudo" else "uC"
            i = o
            while i < len(rest):
                t = rest[i].replace(PH, "")
                bare = t.split("=", 1)[0]
                if bare in LONG_VALUE_FLAGS:
                    i += 1 if "=" in t else min(2, len(rest) - i)
                elif t.startswith("--"):
                    i += 1
                elif t.startswith("-") and len(t) > 1:
                    m = re.search("[" + _VALUE_LETTERS + "]", t[1:])
                    if m:
                        attached = m.end() < len(t[1:])
                        i += 1 if attached else min(2, len(rest) - i)
                    else:
                        i += 1
                else:
                    break
            if i >= len(rest):
                break
            argv0, o = basename(rest[i]), i + 1
        elif argv0 == "rtk":
            # GH #216. Global flags first, then the subcommand; see _RTK_RUNNERS above.
            i = _past_dash_words(rest, o)
            if i >= len(rest):
                break
            sub = rest[i].replace(PH, "")
            if sub == "run":
                j, body = i + 1, None
                while j < len(rest) and rest[j].replace(PH, "").startswith("-"):
                    t = rest[j].replace(PH, "")
                    if t in ("-c", "--command") and j + 1 < len(rest):
                        body = rest[j + 1]
                        break
                    if t.startswith("--command="):
                        body = rest[j].split("=", 1)[1]
                        break
                    j += 1
                if body is not None:
                    # A shell body: hand it to the same one-level -c unwrap as `sh -c`.
                    argv0, rest, o = "sh", ["-c", body], 0
                    break
                if j >= len(rest):
                    break
                # positional args are joined and run through `sh -c` (verified live)
                argv0, rest, o = "sh", ["-c", " ".join(rest[j:])], 0
                break
            elif sub in _RTK_RUNNERS or sub in _RTK_SHELL_RUNNERS:
                j = _past_dash_words(rest, i + 1)
                if j >= len(rest):
                    break
                if sub in _RTK_SHELL_RUNNERS:
                    argv0, rest, o = "sh", ["-c", " ".join(rest[j:])], 0
                    break
                argv0, o = basename(rest[j]), j + 1
            else:  # an rtk verb that dispatches to the real tool of the same name
                argv0, o = basename(rest[i]), i + 1
        elif argv0 in _RUN_WRAPPERS:  # GH #566
            vals, npos, bodies, join = _RUN_WRAPPERS[argv0]
            i, body = o, None
            while i < len(rest) and rest[i].replace(PH, "").startswith("-"):
                t = rest[i].replace(PH, "")
                name = t.split("=", 1)[0]
                if name in bodies:
                    body = t.split("=", 1)[1] if "=" in t else (rest[i + 1] if i + 1 < len(rest) else None)
                    break
                # A body letter bundled in a short cluster (`script -qc 'cmd'`): the rest of the cluster, or the next word.
                k = next((k for k, ch in enumerate(t[1:], 1) if "-" + ch in bodies), 0) if not t.startswith("--") else 0
                if k:
                    body = t[k + 1:] or (rest[i + 1] if i + 1 < len(rest) else None)
                    break
                if t == "--":
                    i += 1
                    break
                i += 2 if t in vals else 1
            if body is None and join is None:
                break  # su without -c runs a login shell, no command
            if body is None:
                i += npos
            if body is None and i < len(rest) and argv0 == "flock" and rest[i].replace(PH, "") in ("-c", "--command"):
                body = rest[i + 1] if i + 1 < len(rest) else None
            if body is not None or join:
                _scan_body(body if body is not None else " ".join(rest[i:]))
                o = len(rest)
                break
            if i >= len(rest):
                break
            argv0, o, via_run_wrapper = basename(rest[i]), i + 1, True
            if o - 1 < len(rest) and argv0 not in _RUN_WRAPPERS:
                pkg = re.sub(r"@[^/@]*$", "", rest[o - 1].replace(PH, ""))
                argv0 = _PKG_PROGRAMS.get(basename(pkg), argv0)
        else:  # command, nohup, time, setsid, builtin — bare flags then the wrapped command
            i = _past_dash_words(rest, o)
            if i >= len(rest):
                break
            argv0, o = basename(rest[i]), i + 1

    rest = rest[o:]
    if argv0 in _SHELL_PUSH_ALIASES:  # GH #750: after the wrappers, so `sudo gp -f` reads as a git push too
        argv0, rest = "git", _SHELL_PUSH_ALIASES[argv0] + rest
    elif argv0 == "grename" and rest:  # its second push takes NEW as one word: `grename x -f` force-pushes
        _WDEPTH[len(windows)] = _cur_depth
        windows.append(["git", "push", "--set-upstream", "origin"] + rest[1:2])
        argv0, rest = "git", ["push", "origin", ":" + rest[0]]

    _unwrap_shell(argv0.replace(PH, ""), rest)  # `s$(true)h -c` is still sh
    _ib = _interp_body(argv0.replace(PH, ""), rest)  # GH #608
    if _ib:
        _ic = _interp_commands(_ib)
        _RM_VIA_INTERP[0] = _RM_VIA_INTERP[0] or bool(_ic)  # #636 review: the API can feed rm's stdin
        for _c in _ic:
            _scan_body(_c)

    if argv0 == "find":
        # GH #227: find -exec sh -c '<body>' \; hides the body in one token. The shell is the
        # word right after the action flag, not the first shell-named word (-name sh).
        # The command after the action flag becomes a window of its own, so a wrapper before
        # the shell (`-exec env sh -c ...`, `-exec rtk run -c ...`) unwraps like anywhere else.
        # Each command runs from its flag to the NEXT action flag, so the appended windows
        # partition `rest` (linear total size): a flood of -exec words, or `find -exec find
        # -exec find ...`, cannot grow the work past the 8s hook timeout.
        acts = [j for j, t in enumerate(rest) if t.replace(PH, "") in ("-exec", "-execdir", "-ok", "-okdir")]
        for n, j in enumerate(acts):
            sub = rest[j + 1:(acts[n + 1] if n + 1 < len(acts) else len(rest))]
            if sub:
                _WDEPTH[len(windows)] = _cur_depth
                windows.append(sub)
                if ("agent_id" in d) and rest[j].replace(PH, "") in ("-exec", "-execdir", "-ok", "-okdir") \
                        and _find_action_spawns(sub):
                    _deny_nested_spawn()
                if rest[j].replace(PH, "") in ("-exec", "-execdir") and _find_action_chmod_world(sub):
                    deny("chmod 777 / a+rwx on every file find yields makes them world-writable — confirm with user first",
                         rule="chmod-world", hint=_CHMOD_HINT)
                if rest[j].replace(PH, "") in ("-exec", "-execdir") and _shell_body_runs_rm(sub):
                    deny("find -exec/-execdir runs rm through a shell body — destructive delete; " + delete_hint(),
                         rule="find-exec-rm")
        if len(acts) > 1:
            # A later `-exec` may be a shell's option letters (`bash -c -exec 'body'`), not a find
            # action: also scan everything after the first action as ONE command. Each such window
            # can be a find again, so the chain is bounded like the xargs one below.
            _count_handover("find/xargs")
            _WDEPTH[len(windows)] = _cur_depth
            windows.append(rest[acts[0] + 1:])

    if argv0 == "xargs":
        # xargs args are never free-text prose, so scanning for a dangerous
        # basename anywhere in them is safe; "git" is included so the git
        # checks fire on the xargs-wrapped form. Full PH removal: a splice can
        # land mid-basename (xargs g$(true)it).
        for j, t in enumerate(rest):
            if basename(t).replace(PH, "") in _SHELLS:  # GH #227: xargs sh -c '<body>'
                _unwrap_shell(basename(t).replace(PH, ""), rest[j + 1:])
                break
        for j, t in enumerate(rest):  # xargs env sh -c / xargs rtk run -c: a wrapper hands over the command
            if basename(t).replace(PH, "") in _STEP_WRAPPERS:
                # Each wrapper window re-enters this branch when it hands over another xargs and
                # copies its tail: chained `xargs env xargs env ...` is quadratic, so bound the chain.
                _count_handover("xargs")
                _WDEPTH[len(windows)] = _cur_depth
                windows.append(rest[j:])
                break
        _xc = _xargs_command(rest)
        # Bypass hunt 2026-10-23 F5: `find | xargs rm` deletes every path it is fed, the same delete as
        # `find -exec rm`, which denies with no flags at all. Wrappers between (`xargs sudo -u x rm`,
        # `xargs nice -n 5 rm`, `xargs env FOO=1 rm`, `xargs timeout 5 rm`) are read past.
        _xr = _xc
        while _xr < len(rest) and basename(rest[_xr]).replace(PH, "") in _STEP_WRAPPERS:
            _xr = _past_wrapper_words(basename(rest[_xr]).replace(PH, ""), rest, _xr + 1)
        # GH #591: xargs hands mkfs its device as a word, so the mkfs rule's operand test never sees one.
        _xm = basename(rest[_xr]).replace(PH, "") if _xr < len(rest) else ""
        # Only --help / --version alone run nothing: the short letters differ per tool (mkfs's -V is
        # --verbose, mkfs.vfat's -h takes a hidden-sector count), and every word must be one of them
        # (`-L --version`: --version is the label).
        _xinfo = ("--help", "--version")
        _xargs_m = [t.replace(PH, "") for t in rest[_xr + 1:]]
        if (_xm in ("mkfs", "mke2fs") or _xm.startswith("mkfs.")) and not (
                _xargs_m and all(t in _xinfo for t in _xargs_m)):
            deny("mkfs formats a filesystem — irrecoverable disk-level destruction", rule="mkfs")
        if _xr < len(rest) and basename(rest[_xr]).replace(PH, "") == "rm":
            deny("xargs rm deletes every path it is fed — destructive delete; " + delete_hint(), rule="xargs-rm")
        for j, t in enumerate(rest):
            if basename(t).replace(PH, "") in ("rm", "find", "dd", "gdd", "git"):
                argv0, rest = basename(t), rest[j + 1:]
                break
        else:
            # gh only as the command xargs runs, since "gh" is also a common grep pattern: `xargs grep
            # -l gh src` must not read as gh.
            if _xc < len(rest) and basename(rest[_xc]).replace(PH, "") == "gh":
                argv0, rest = "gh", rest[_xc + 1:]
    elif argv0 in _CONTAINER_TOOLS:
        # The command a container tool runs inside (`docker exec db psql ...`) is checked by every rule
        # as if it ran here (GH #584).
        # A window of its own, so a wrapper inside the container (`docker exec db env A=1 psql ...`)
        # unwraps like anywhere else.
        inner = _container_exec_command(argv0, rest)
        if inner:
            _WDEPTH[len(windows)] = _cur_depth
            windows.append(inner)

    # GH #336. Outside the candidate loop below: a PH argv0 (`${EDITOR} f`) must not read as mkfs.
    # PH is stripped instead, so a splice inside the word (`mk$(true)fs.ext4`) still matches.
    _a0 = argv0.replace(PH, "")
    # GH #566: a subagent's claude reached through a wrapper the spawn anchor does not walk (flock, npx, ...).
    # Only past one of those wrappers: elsewhere the anchor decides, and a window can read `claude` as argv0 where
    # the shell does not run it (`builtin claude`, `"A=1" claude`).
    if via_run_wrapper and "agent_id" in d and _a0 == "claude" and any(t.replace(PH, "").split("=", 1)[0] in _SPAWN_WINDOW_FLAGS for t in rest):
        _deny_nested_spawn()
    # GH #621: the spawn anchor reads the raw -S text, so env's own word breaks (`claude\_-p\_hi`) hide claude's
    # words from it; past an env -S split the words env runs are read here.
    if env_splits and "agent_id" in d and _a0 == "claude" and _claude_words_spawn(rest):
        _deny_nested_spawn()
    if (_a0 in ("mkfs", "mke2fs") or _a0.startswith("mkfs.")) and any(
            not t.replace(PH, "").startswith("-") for t in rest):
        deny("mkfs formats a filesystem — irrecoverable disk-level destruction", rule="mkfs")
    if _a0 in ("chmod", "gchmod") and _chmod_world(rest):  # gchmod: GNU chmod from Homebrew (GH #587)
        deny("chmod 777 / a+rwx recursively or on / or ~ makes files world-writable — confirm with user first",
             rule="chmod-world", hint=_CHMOD_HINT)
    if (_a0 in ("trash", "trash-put") and _trash_whole_tree(rest)) or (
            _a0 == "gio" and rest and rest[0].replace(PH, "") == "trash" and _trash_whole_tree(rest[1:])):
        deny("trash of /, ~, ., *, an empty word, $HOME or $PWD moves a whole tree to the trash — check the "
             "argument is non-empty and names the path you mean (a variable: \"${X:?}\")", rule="trash-whole-tree")
    if not _in_value and _opaque_var(argv0, rest):
        ask("the program this runs is a variable with no visible assignment — confirm what it runs",
            rule="opaque-var-verb")
    # GH #595: activating a virtualenv is routine, so one path ending bin/activate(.fish|.csh) is not asked about.
    if argv0 in ("source", ".") and rest and not _venv_activate(rest):
        ask("source runs a file's commands in this shell, unchecked — confirm what it runs", rule="source-file")

    for argv0 in _candidates(argv0, KNOWN_DANGEROUS):
        if argv0 == "rm":
            # Lowercase so "rm -Rf" matches. A SHORT bundled cluster counts
            # per-character; a LONG option only as a prefix of --recursive/--force
            # (bare letter membership across long flags false-positived on
            # "--before=1" once candidate duplication ran this on any command).
            # GNU rm takes any unambiguous prefix, and its long options (force,
            # interactive, one-file-system, no-preserve-root, preserve-root,
            # recursive, dir, verbose, help, version) leave --r and --f unambiguous.
            has_r = has_f = False
            for t in rest:
                # GH #594: after a bare `--` every word is an operand, in a plain command only (_RM_PLAIN_DASHDASH).
                if t == "--" and _RM_PLAIN_DASHDASH:
                    break
                # "$(true)-rf" IS "-rf" in bash but blanks to "PH-rf", which no
                # longer starts with "-" -- strip PH, assume the dangerous
                # (empty-substitution) resolution.
                t = t.replace(PH, "")
                if t.startswith("--"):
                    has_r = has_r or _is_flag(t, "--recursive")
                    has_f = has_f or _is_flag(t, "--force")
                elif t.startswith("-") and len(t) > 1:
                    body = t[1:].lower()
                    has_r = has_r or "r" in body
                    has_f = has_f or "f" in body
            if has_r and has_f:
                deny("rm -rf detected — " + delete_hint(), rule="rm-rf")
            # GH #336: GNU rm takes any unambiguous prefix (`--n` is the only `--n...` option).
            if any(_is_flag(t.replace(PH, ""), "--no-preserve-root") for t in rest):
                deny("rm --no-preserve-root lifts rm's guard on / — " + delete_hint(), rule="rm-no-preserve-root")
            # 2026-10-25 (out-of-contract follow-up to the 2026-10-24 sweep): without -f, rm -r still deletes
            # the tree with no undo; -f only adds silence on write-protected files and missing paths. -i
            # prompts for every file, and the Bash tool's stdin gives no yes, so it deletes nothing unasked:
            # unless a later -f/-I/--interactive=never|once overrides it, it sits after "--", or the command
            # feeds rm's stdin (#611 review; _rm_prompts_each, _rm_stdin_fed).
            if has_r and not has_f and not (
                    _rm_prompts_each(rest)
                    and not _rm_stdin_fed()):
                deny("rm -r deletes a directory tree with no undo, -f or not — " + delete_hint(), rule="rm-recursive")

        # Same PH-erases-flag-shape fix as the rm block ("find $(true)-exec").
        if argv0 == "find" and _find_actions(rest, "-exec", "-execdir") and "rm" in [basename(t) for t in rest]:
            deny("find -exec/-execdir rm detected — destructive delete; " + delete_hint(), rule="find-exec-rm")
        if argv0 == "find" and _find_actions(rest, "-delete"):
            deny("find -delete detected — destructive delete; " + delete_hint(), rule="find-delete")

        if argv0 == "git" and rest:
            # --no-verify skips pre-commit/pre-push hooks; checked per window (a
            # global check over `tokens` only saw the last line). Git-specific
            # so `echo "--no-verify"` does not false-positive.
            if any(_is_flag(t.replace(PH, ""), "--no-verify") for t in w):
                deny("--no-verify bypasses safety hooks", rule="git-no-verify")
            # -c core.hooksPath=<path> (split or joined "-ccore.hooksPath=X")
            # re-points git at a different hooks dir -- same bypass as
            # --no-verify. An empty value trips it too: it unwires every hook.
            # Case-insensitive key match (git config keys are case-insensitive;
            # `-c core.hookspath=` re-points hooks exactly like the canonical
            # spelling, live-confirmed) -- only the KEY is lowercased for the
            # comparison, the captured VALUE keeps its original case. The
            # sibling `config` subcommand branch two arms below already does
            # this; this arm predated it and was missed.
            if _sets_hooks_path(w):
                deny("-c core.hooksPath=<path> re-points git at a different hooks dir — same bypass as --no-verify", rule="git-hooks-path")
            # GH #375: the global flags re-read as shell words (glued tokens joined), so `-C $R`,
            # `-C$R`, `--git-dir=$G` and `-c k=a@b` hold one value, are checked as a window of their
            # own. This window keeps the token reading below: a deny in either wins.
            for _pv in (False, True):
                _gw = _git_words(rest, _pv)
                if _gw:
                    _WDEPTH[len(windows)] = _cur_depth
                    windows.append(["git"] + _gw)
            # Walk past leading global flags so ` git -C /repo push --force`
            # (or -Cpath, --no-pager) does not set sub="-C" and bypass the gate.
            i = 0
            while i < len(rest) and rest[i].replace(PH, "").startswith("-"):
                t = rest[i].replace(PH, "")
                if t in GIT_VALUE_GLOBALS:
                    i += 2  # bare value-taking global → skip flag + its value
                    continue
                # combined form carrying the value in the same token
                # (-Cpath, --git-dir=path, --config-env=name=val) → skip 1
                if (t.startswith("-C") and t != "-C") or \
                   t.startswith(tuple(g + "=" for g in GIT_VALUE_GLOBALS if g.startswith("--"))):
                    i += 1
                    continue
                i += 1  # any other leading flag (non-value global: --no-pager, -p, …)
            if i >= len(rest):
                continue  # only global flags, no subcommand — safe no-op
            sub, args = rest[i], rest[i + 1:]
            # The ambiguity verb regex stops after ~400 chars of globals; the sub resolved here has no
            # such bound, so a brace-hidden flag after 100 "-C ." is still caught (deep-audit 2026-10-01).
            if _ambig and _ambig[1] is _AMBIG_BROAD_VERB_RE and sub.replace(PH, "") in (
                    "push", "reset", "clean", "checkout", "restore", "switch", "branch", "stash"):
                _deny_ambiguous()
            # GH #561: what a -c pair makes of this subcommand (an alias names it, or a key re-enables a deny).
            _sub = sub.replace(PH, "")
            # One pass: git keeps the last alias.<name>, so each alias is expanded once (PR #571 review:
            # one scan per alias pair was quadratic). The risk keys and the verb rules read the typed verb
            # and every verb along the alias chain, any deny wins (round 3 review: git runs a built-in
            # over an alias of its name). Risk keys are not merged: a remote's name is case-sensitive,
            # so any dangerous pair counts.
            _aliases, _risks = {}, []
            for _k, _v in _git_cfg_pairs(rest[:i]):
                if _k.startswith("alias."):
                    _aliases[_k[len("alias."):]] = _v
                else:
                    _risks.append((_k, _v))
            _steps, _how, _body = _git_alias_chain(_aliases, _sub)
            for _verb, _pre in _steps:
                _rverb = _verb.replace(PH, "")
                for _k, _v in _risks:
                    _r = _git_cfg_risk(_k, _v, _rverb)
                    if _r == "git-clean-force" and _git_clean_dry_run(_pre + args):
                        _r = None  # a dry run (clean -n, -xdn) or the prompt deletes nothing unasked
                    if _r:
                        deny("git -c " + _k + "=" + _v + " makes `git " + _rverb + "` do what its denied flag does — confirm with user first", rule=_r)
            if _body is not None and _body is not _GIT_CFG_UNSEEN:
                # A ! alias's shell line runs with the -c keys in effect (git passes them on in
                # GIT_CONFIG_PARAMETERS), so a risky key under one is the risky run (round 3 review).
                for _k, _v in _risks:
                    _r = _git_cfg_risk(_k, _v, None)
                    if _r:
                        deny("git -c " + _k + "=" + _v + " is in effect for every git the " + _how + " shell line runs — confirm with user first", rule=_r)
            if _body is not None:
                _git_alias_check(_body, _steps[-1][1] + args, _how)
            # git runs the first built-in along the chain, else the last verb. A verb in the middle that
            # is not a gated built-in only names the next alias, so it is not scanned: one scan per
            # step with the user's words was 2.7 s on a 130 KB ten-step chain.
            for _n, (_verb, _pre) in enumerate(_steps[1:], 2):
                if _n == len(_steps) or _verb.replace(PH, "").lower() in KNOWN_GIT_SUBS + ("config",):
                    _GIT_ALIAS_SCANNED[0] = True
                    _scan_body("git " + " ".join([_verb] + _pre + args))
            # drop the value token after a free-text flag so message content
            # (e.g. "commit -m ...rm -rf...") is never pattern-matched.
            scan_raw, skip = [], False
            for t in args:
                if skip:
                    skip = False
                    continue
                # restore's and checkout's -m is --merge and branch's is --move (no value);
                # skipping the next token would eat the pathspec or branch name (GH #249,
                # deep-audit 2026-09-30). An unresolved sub (PH / raw substitution) may be
                # either, so it does not skip.
                if t.replace(PH, "") in ("-m", "--message") and not (
                        sub in ("restore", "checkout", "branch") or PH in sub or _has_raw_subst(sub)):
                    skip = True
                    continue
                if t == "":  # only a word window keeps an empty word; git rejects it as a pathspec or ref
                    continue
                scan_raw.append(t)
            # "$(true)--force" IS "--force" in bash but blanks to "PH--force";
            # strip PH once here so every sub == "..." branch below sees the
            # flag shape. scan_raw (pre-strip) is kept index-aligned alongside
            # for the PSUB-identity checks below: a glued "$(...)<(...)" token
            # (no space between them -- one shlex token, "PH_char+PSUB_char")
            # collapses to a value textually identical to a lone PSUB once PH
            # is stripped out, wrongly inheriting PSUB's "safe to exclude"
            # treatment even though the $(...) half is attacker-controlled.
            # Checking the RAW (pre-strip) token for exact PSUB identity
            # instead of the stripped one closes that (deep-audit, 2026-09-29).
            scan = [t.replace(PH, "") for t in scan_raw]

            for sub in _candidates(sub, KNOWN_GIT_SUBS):
                # Spec v3: a lease (--force-with-lease[=..], --force-if-includes) counts as forced too, so
                # _FORCE_PUSH_OK (the strict whole-command shape, no protected dst) is its only allow.
                if sub == "push" and not _FORCE_PUSH_OK and any(
                    t.startswith("--force")
                    or (t.startswith("-") and not t.startswith("--") and "f" in t)
                    or t.startswith("+")  # "+refspec" force-pushes without a -f/--force flag
                    for t in scan
                ):
                    deny("git push --force overwrites remote history — needs explicit user approval (allowed only as one plain `git push [opts] <remote> <src:dst>` to a non-protected branch)", rule="git-push-force")
                # `git config core.hooksPath X` / --unset disables pre-commit and
                # pre-push (same bypass class as --no-verify). The documented
                # wiring value `git-hooks` stays allowed.
                # GH #561: a stored alias or key does at the next run what the -c pair above does now.
                _cw = _git_config_write(args) if sub == "config" else None
                if _cw and _cw[0].lower().startswith("alias."):
                    _git_alias_check(_cw[1], [], "git config " + _cw[0])
                if _cw and _git_cfg_risk(_cw[0].lower(), _cw[1], None):
                    deny("git config " + _cw[0] + " " + _cw[1] + " makes a later git run do what a denied flag does — confirm with user first",
                         rule=_git_cfg_risk(_cw[0].lower(), _cw[1], None))
                # GH #562: the decision reads args, not scan: scan drops an empty word, and `core.hooksPath ""`
                # (an empty value, which unwires every hook) then read as the key alone, a read.
                _cfg = [t.replace(PH, "") for t in args] if sub == "config" else None
                if _cfg and ((any(t.lower() == "core.hookspath" for t in _cfg) and not _hooks_path_ok(_cfg))
                             or _drops_core_section(args)):
                    deny("git config core.hooksPath rewires/disables the repo git hooks — only `git config core.hooksPath git-hooks` is allowed", rule="git-config-hooks-path")
                if sub == "reset" and any(_is_flag(t, "--hard") for t in scan):
                    deny("git reset --hard discards uncommitted work — confirm with user first", rule="git-reset-hard", hint=_SAVE_HINT + ", or, in the main session, move HEAD with `git reset --keep <ref>`, which refuses to lose local changes")
                # SHORT bundled cluster counts per-character, LONG option via
                # _is_flag's prefix match (bare containment false-positived on
                # "--find-renames" / "--format=fuller" under candidate duplication --
                # _is_flag is safe against both, see its own docstring above).
                if sub == "clean" and any(
                    _is_flag(t, "--force") or (t.startswith("-") and not t.startswith("--") and "f" in t)
                    for t in scan
                ):
                    deny("git clean -f deletes untracked files — confirm with user first", rule="git-clean-force", hint="or, in the main session, preview with `git clean -n`; then move the files aside with `mv` or commit them")
                # git restore: default mode and --worktree target the WORKTREE
                # (unrecoverable); --staged alone targets the INDEX (recoverable,
                # allowed). Unlike checkout, a restore pathspec is never a branch
                # switch, so a worktree-targeting pathspec is always destructive.
                if sub == "restore":
                    # A PURE PSUB token is a real nonflag argument but never a
                    # real worktree pathspec restore could discard (its
                    # expanded value is always a synthesized "/dev/fd/<n>"
                    # path) -- same reasoning as checkout's _co_nonflag
                    # exclusion above; missed here on the first pass, found
                    # by a deep-audit pass (2026-09-29). Checked against
                    # scan_raw (pre-PH-strip), not scan, so a glued
                    # "$(...)<(...)" token that only LOOKS like a lone PSUB
                    # after stripping still counts (see scan_raw's own
                    # comment above).
                    # --pathspec-from-file's VALUE is read by git as a list of
                    # real pathspecs, so the flag alone means path mode
                    # regardless of what its argument token looks like --
                    # excluding a bare PSUB from the nonflag count is wrong
                    # for THIS flag specifically, since the process
                    # substitution's OUTPUT, not the token itself, is the
                    # actual pathspec source (also closes the same gap for
                    # --pathspec-from-file=<file>/- with no substitution at
                    # all, GH #189).
                    has_pathspec = ("." in scan or "--" in scan or
                                    any(_is_flag(t.split("=", 1)[0], "--pathspec-from-file") for t in scan) or
                                    any(not t.startswith("-") and traw != PSUB
                                        for t, traw in zip(scan, scan_raw)))
                    # GH #189: -W (bundled too) and any --worktree
                    # abbreviation ("--work") count; a short cluster stops at
                    # "s" (-s takes a value: "-sW" is source "W"). After "--"
                    # every token is a pathspec ("-- -Wfile").
                    _opts, _val = [], False
                    for t in (scan[:scan.index("--")] if "--" in scan else scan):
                        if _val:  # the value of -s/--source/--pathspec-from-file is not a flag (GH #249)
                            _val = False
                            continue
                        _opts.append(t)
                        if t.startswith("-") and not t.startswith("--"):
                            _val = t.find("s") == len(t) - 1 and t != "-"
                        else:
                            _val = "=" not in t and (_is_flag(t, "--source") or _is_flag(t, "--pathspec-from-file"))
                    # GH #197: -S is --staged; same cluster rule as -W (stops at "s").
                    _staged = any(_is_flag(t, "--staged")
                                  or (t.startswith("-") and not t.startswith("--") and "S" in t.split("s", 1)[0])
                                  for t in _opts)
                    targets_worktree = not _staged or any(
                        _is_flag(t, "--worktree")
                        or (t.startswith("-") and not t.startswith("--") and "W" in t.split("s", 1)[0])
                        for t in _opts)
                    if has_pathspec and targets_worktree:
                        deny("git restore discards working-tree changes — confirm with user first", rule="git-restore", hint=_SAVE_HINT)
                # checkout: "--"/"." = discard; 2+ nonflag = tree-ish + path
                # (`git checkout HEAD~1 file` overwrites the worktree). 1 nonflag
                # stays allowed: it may be a legit branch switch.
                # -b/-B/--orphan consume one nonflag (the new branch name), so
                # `checkout -b feat origin/develop` is a create, not tree+path.
                # A PURE PSUB token (GH #181: `checkout main <(true)`) is a real
                # nonflag arg but never a real worktree pathspec (its expanded
                # value is always a synthesized "/dev/fd/<n>" path, not
                # attacker-controlled the way "$(...)" is), so it's excluded
                # here rather than counted toward the tree-ish+path deny.
                # Checked against scan_raw (pre-PH-strip), not scan -- see
                # scan_raw's own comment above; a glued "$(...)<(...)" token
                # only LOOKS like a lone PSUB after PH-stripping.
                # --pathspec-from-file is checked separately, unconditionally
                # of _co_nonflag: its VALUE is read by git as a list of real
                # pathspecs regardless of how many other nonflag args are
                # present (deep-audit, 2026-09-29; same reasoning as
                # restore's identical check above).
                # `--conflict <style>` takes its style word as a separate value (merge, diff3, zdiff3), so that
                # word is no path; `--conflict=<style>` is one token and needs nothing.
                _co_conflict = sum(1 for k, t in enumerate(scan[:-1])
                                   if "=" not in t and _is_flag(t, "--conflict") and not scan[k + 1].startswith("-"))
                _co_nonflag = len([t for t, traw in zip(scan, scan_raw) if not t.startswith("-") and traw != PSUB]) - (
                    1 if any(t in ("-b", "-B", "--orphan") for t in scan) else 0) - _co_conflict
                if sub == "checkout" and ("--" in scan or "." in scan or
                                            _co_nonflag >= 2 or
                                            any(_is_flag(t.split("=", 1)[0], "--pathspec-from-file") for t in scan) or
                                            any(t == "-f" or _is_flag(t, "--force") or _bundled_flag(t, ("b", "B")) for t in scan)):
                    deny("git checkout -- / git checkout . / git checkout -f / git checkout <tree> <file> discards working-tree changes — confirm with user first", rule="git-checkout-discard", hint=_SAVE_HINT)
                if sub == "switch" and any(t == "-f" or _is_flag(t, "--force", "--discard-changes") or _bundled_flag(t, ("c", "C")) for t in scan):
                    deny("git switch --force discards working-tree changes — confirm with user first", rule="git-switch-force", hint="or commit first, then a plain `git switch`")
                # A force-delete is allowed only for a whole command of the plain shape
                # "git [-C <path>] branch <flags and names>" in which no name's last path part
                # is main/master/develop in any case ("origin/main", "Main" on a case-
                # insensitive filesystem). Anything else keeps the deny (operator policy,
                # 2026-09-30): the per-window token view cannot prove what git receives
                # (a quoted ";" or a mid-word "{" splits the window, xargs appends names,
                # "@{-1}" is the previous branch), so a whitelist on the raw text decides.
                if sub == "branch" and (
                    any(t == "-D" or (t.startswith("-") and not t.startswith("--") and "D" in t) for t in scan)
                    # -d -f, -df, -fd, -d --force and --delete -f are -D by another spelling.
                    or (any(_is_flag(t, "--delete") or _bundled_flag(t, "", "d") for t in scan)
                        and any(_is_flag(t, "--force") or _bundled_flag(t, "", "f") for t in scan))
                ):
                    _m = _BRANCH_D_PLAIN_RE.fullmatch(cmd.strip())
                    _names = [t for t in (_m.group(1).split() if _m else []) if not t.startswith("-")]
                    if not _names or any(_protected_ref(t) for t in _names):
                        deny("git branch -D is allowed only as a plain `git branch -D <names>` without main/master/develop — confirm with user first", rule="git-branch-force-delete")
                if sub == "stash" and args and args[0].replace(PH, "") in ("drop", "clear"):
                    deny("git stash drop/clear discards stashed changes — confirm with user first", rule="git-stash-drop", hint="or leave the stash in place; keeping it loses nothing")
                if sub == "commit" and any(_is_flag(t, "--amend") for t in scan):
                    deny("git commit --amend rewrites history — confirm with user first", rule="git-commit-amend", hint="or make a new commit instead")
                # `commit -n` is --no-verify (push -n is --dry-run, merge -n --no-stat, so
                # commit only). Cluster stops at a value-taking letter: -mnew is a message,
                # -Fnotes.txt a file, -tnotes a template, -uno the untracked-files mode.
                if sub == "commit" and any(_bundled_flag(t, "mFtu", "n") for t in scan):
                    deny("git commit -n is --no-verify, it bypasses safety hooks", rule="git-commit-n")
                # 2026-10-23 bypass sweep: other verbs with the same damage as a deny above.
                _nonflag = [t for t in scan if not t.startswith("-")]
                if sub == "push" and any(_is_flag(t, "--mirror", "--prune") for t in scan):
                    deny("git push --mirror/--prune overwrites or deletes remote refs, like --force — confirm with user first", rule="git-push-mirror", hint="or push named refs (`git push origin <branch>`)")
                # GH #563 review: send-pack (push's plumbing) deletes with the same ":ref" refspec; --delete
                # and -d are not send-pack options (git rejects them), so mirroring them only over-denies.
                if sub in ("push", "send-pack") and (
                        any(t.startswith(":") and _protected_ref(t[1:]) for t in _nonflag)
                        or (any(_is_flag(t, "--delete") or _bundled_flag(t, "", "d") for t in scan)
                            and any(_protected_ref(t) for t in _nonflag[1:]))):
                    deny(f"git {sub} deleting main/master/develop on the remote — confirm with user first", rule="git-push-delete-protected")
                if sub == "read-tree" and any(_is_flag(t, "--reset") for t in scan) and "-u" in scan:
                    deny("git read-tree -u --reset discards uncommitted work, like reset --hard — confirm with user first", rule="git-read-tree-reset")
                if sub == "checkout-index" and any(t == "-f" or _is_flag(t, "--force") or _bundled_flag(t, "", "f") for t in scan):
                    deny("git checkout-index -f overwrites working-tree files — confirm with user first", rule="git-checkout-index-force")
                if sub == "worktree" and _nonflag[:1] == ["remove"] and any(
                        t == "-f" or _is_flag(t, "--force") or _bundled_flag(t, "", "f") for t in scan):  # -ff: GH #563
                    deny("git worktree remove --force deletes the worktree's uncommitted changes — confirm with user first", rule="git-worktree-remove-force", hint="or commit inside it (stage untracked files by name too), then a plain `git worktree remove <path>`")
                # The reflog is the way back after a reset or a branch delete; these empty it now, not in 90 days.
                _now = lambda v: v.lower() in ("now", "all", "0")
                _vals = [t.split("=", 1)[1] for t in scan if "=" in t] + [
                    scan[k + 1] for k, t in enumerate(scan[:-1]) if "=" not in t and _is_flag(t, "--expire", "--expire-unreachable", "--prune")]
                if (sub == "reflog" and (_nonflag[:1] == ["delete"] or (_nonflag[:1] == ["expire"] and any(_now(v) for v in _vals)))
                        or sub == "gc" and any(_now(t.split("=", 1)[1]) for t in scan if _is_flag(t.split("=", 1)[0], "--prune") and "=" in t)
                        # A bare prune keeps what a reflog still names; only an explicit now/all reaches it.
                        or sub == "prune" and not any(t == "-n" or _is_flag(t, "--dry-run") or _bundled_flag(t, "", "n") for t in scan)
                        and any(_now(v) for v in _vals)):
                    deny("git reflog expire/delete, gc --prune=now and prune remove the history a reset or branch delete could be undone from — confirm with user first", rule="git-reflog-prune")
                if sub == "update-ref" and any(t == "-d" or _is_flag(t, "--delete") for t in scan) and any(_protected_ref(t) for t in _nonflag):
                    deny("git update-ref -d on main/master/develop deletes a protected branch, like branch -D — confirm with user first", rule="git-update-ref-delete-protected")
                if sub == "branch" and (
                        any(t in ("-M", "-C") or (t.startswith("-") and not t.startswith("--") and ("M" in t or "C" in t)) for t in scan)
                        # -fm, -mf, -fc, -cf: the force and the move/copy bundled (GH #563 follow-up); -u takes a value.
                        or (any(_bundled_flag(t, "u", "m") or _bundled_flag(t, "u", "c") or _is_flag(t, "--move", "--copy") for t in scan)
                            and any(_bundled_flag(t, "u", "f") or _is_flag(t, "--force") for t in scan))) and any(_protected_ref(t) for t in _nonflag[-1:]):
                    deny("git branch -M/-C onto main/master/develop overwrites a protected branch — confirm with user first", rule="git-branch-force-move-protected")
                # GH #563 (2026-10-24 sweep): more verbs with a denied verb's damage. send-pack is push's
                # plumbing; rm -f drops a tracked file's uncommitted edits (--cached leaves the worktree);
                # branch -f and update-ref without -d move main/master/develop like branch -M does.
                _force = any(t == "-f" or _is_flag(t, "--force") or _bundled_flag(t, "", "f") for t in scan)
                # send-pack lists "-f, --force", bundled too (-vf, -qf); no short option of it takes a value.
                if sub == "send-pack" and (_force or any(_is_flag(t, "--mirror") for t in scan) or any(t.startswith("+") for t in _nonflag)):
                    deny("git send-pack --force/--mirror/+refspec overwrites remote history, like push --force — confirm with user first", rule="git-push-force")
                # GH #563 review: a dry run (-n, bundled as in -nf, or --dry-run / a prefix) and --cached
                # delete nothing from the worktree. git reads rm's options in order, so the last of each
                # pair wins (-f/--no-force, -n/--no-dry-run, --cached/--no-cached); only words before "--"
                # are options (after it "-f" is a path), and a bare --pathspec-from-file takes the next word.
                if sub == "rm" and _rm_forced(scan):
                    deny("git rm -f discards the uncommitted changes of the files it removes — confirm with user first", rule="git-rm-force", hint="or commit the changes first, then plain `git rm`")
                if sub == "branch" and _force and _nonflag and _protected_ref(_nonflag[0]) and not any(
                        t.startswith("-") and not t.startswith("--") and any(c in t for c in "dDmMcC")
                        or _is_flag(t, "--delete", "--move", "--copy") for t in scan):
                    deny("git branch -f onto main/master/develop moves a protected branch — confirm with user first", rule="git-branch-force-move-protected")
                if sub == "update-ref" and not any(t == "-d" or _is_flag(t, "--delete", "--stdin") for t in scan) and _nonflag[:1] and _protected_ref(_nonflag[0]):
                    deny("git update-ref on main/master/develop moves a protected branch — confirm with user first", rule="git-update-ref-delete-protected")
                # -A also arrives bundled (-Af, -fA, -vA); add has no value-taking short flag.
                # --pathspec-from-file's value is a pathspec list the gate cannot read
                # (GH #200), so any use denies, as in restore/checkout above.
                if sub == "add" and (_exclude_only_pathspecs(scan) or any(t == "." or _whole_tree_pathspec(t) or (t and not t.strip(":") and not nxt.startswith(("/", "(", "!", "^"))) or _whole_tree_pathspec(t + nxt) or _bundled_flag(t, "", "A") or _is_flag(t, "--all")
                                        or _is_flag(t.split("=", 1)[0], "--pathspec-from-file")
                                        for t, nxt in zip(scan, scan[1:] + [""]))) and not _mid_merge():
                    deny("git add -A/. stages everything — stage files by name instead "
                         "(allowed only while a merge is in progress, i.e. MERGE_HEAD exists)", rule="git-add-all")

        # Phase B (2026-09-28): local, interactive-session-only defense-in-depth
        # for this repo's PR-review flow -- ask, never deny, since a merge can be
        # a legitimate operator-approved action. Does NOT constrain a GitHub
        # credential used outside a Claude Code session with mh loaded (a cloud
        # Routine, the web UI, a raw API call) -- see docs/adr/0004-* for that
        # threat model; branch protection on develop is the real enforcement there.
        if argv0 == "gh" and rest:
            gh_scan = _gh_group_first([t.replace(PH, "") for t in rest])
            # Help runs nothing, except under extension exec, which hands --help to the extension.
            # An alias or extension (gh-unknown-subcommand below) still asks.
            gh_write = _gh_builtin_write(gh_scan)
            gh_runs = not (_gh_help(gh_scan) and gh_scan[0] in _GH_BUILTINS and gh_write != "extension exec")
            # GH #565: the verb (pr's first positional word) and the endpoint's merge segment, not the word
            # anywhere: `gh pr list --search merge` and `gh api .../contents/lib/merge_sort.py` are reads.
            # GH #621: a mid-word "#" arrives as HASH_LIT, so the endpoint check reads it back as "#".
            if gh_runs and gh_scan[0] == "pr" and [gh_scan[1:][k] for k in _gh_words(gh_scan[1:], 1)] == ["merge"]:
                ask("gh pr merge would merge a pull request into this repo — the PR-review "
                    "flow (docs/reference/branching-model.md) expects a human to do this. "
                    "Confirm this is intentional.", rule="gh-pr-merge")
            if gh_runs and gh_scan[0] == "api" and any(re.search(r"/merge(?:$|[/?#])", t.replace(HASH_LIT, "#")) for t in gh_scan[1:]):
                ask("gh api .../merge calls the GitHub merge endpoint directly — the "
                    "PR-review flow (docs/reference/branching-model.md) expects a human to "
                    "do this. Confirm this is intentional.", rule="gh-api-merge")
            if gh_runs and gh_write:
                ask(f"gh {gh_write} is a T3/T4 write by CLAUDE.md's Risk tiers (no undo, a credential "
                    "or third-party code, or it starts CI). Confirm this is intentional.", rule="gh-builtin-write")
            if gh_runs and gh_scan[0] == "api" and _gh_api_write(gh_scan[1:]):
                ask("gh api would write to GitHub (a non-GET method, a field or --input, or a graphql "
                    "mutation) — a T3 change by CLAUDE.md's Risk tiers unless it is an issue/PR comment "
                    "or label. Confirm this is intentional.", rule="gh-api-write")
            # Only a "gh <sub>" written in the command: the KNOWN_DANGEROUS splice duplication and the
            # views put a candidate "gh" before any word ("rm${IFS}-rf build" yields "gh build").
            if (re.fullmatch(r"[a-z][a-z0-9-]*", gh_scan[0]) and gh_scan[0] not in _GH_BUILTINS
                    and gh_scan[0] in _gh_written_subs()):
                ask(f"gh {gh_scan[0]} is not a built-in gh command — an alias or extension can run "
                    "gh api out of sight. Confirm what it runs.", rule="gh-unknown-subcommand")

        if argv0 in ("dd", "gdd"):  # gdd: GNU dd from Homebrew coreutils (GH #585)
            for t in rest:
                key, eq, target = t.partition("=")
                if not eq or key.replace(PH, "") != "of":  # `$(true)of=` is `of=` (an empty splice)
                    continue
                # GH #585: the target as far as the text shows it, up to a variable or substitution.
                # `//dev/x` and `/./dev/x` name /dev/x too (POSIX keeps a leading `//`; macOS and Linux
                # resolve it to `/`), so the path is collapsed before the prefix test.
                shown = re.split(r"[$`" + PH + "]", target, 1)[0]
                path = os.path.normpath(re.sub("/+", "/", shown)) if shown else ""
                opaque = shown != target
                in_dev = path == "/dev" or path.startswith("/dev/")  # `of=/dev/$DISK` shows only `/dev/`
                if in_dev and path not in _DD_SAFE_DEVICES and not path.startswith("/dev/fd/"):
                    deny("dd writing to a raw device — irrecoverable disk-level destruction", rule="dd-device")
                elif opaque and not in_dev and not _DD_SAFE_VAR_RE.match(target):
                    ask("dd writes to a target the command does not show (a variable or substitution) — "
                        "confirm it is not a raw device", rule="dd-device")

        if argv0 in _SQL_CLIENTS:
            # SQL genuinely lives inside -e/-c values, so DO scan them, but only
            # for known-dangerous statements. TABLE is optional in TRUNCATE
            # grammar. Full PH removal: a splice can land mid-keyword (DR$(true)OP).
            if _SQL_DROP_RE.search(" ".join(rest).replace(PH, "")):
                deny("destructive data command (DROP, TRUNCATE, DELETE or UPDATE with no WHERE, dropDatabase/drop/deleteMany({}), "
                     "FLUSHALL/FLUSHDB) detected — confirm with user first", rule="sql-drop")

    # 2026-10-24 sweep: the client tools that drop a database without SQL. dropdb drops the user's own
    # database when no name is given, so anything but a help or version request denies.
    if _a0 == "dropdb" and not all(t.replace(PH, "") in ("--help", "-?", "--version", "-V") for t in rest):
        deny("dropdb drops a database — confirm with user first", rule="sql-drop")
    if _a0 in ("mysqladmin", "mariadb-admin") and any(t.replace(PH, "").lower() == "drop" for t in rest):
        deny("mysqladmin drop drops a database — confirm with user first", rule="sql-drop")
    # GH #607: rsync --delete (and --del, --delete-after, --delete-excluded, ...) removes every file in the
    # destination the source lacks. A mirror is often what was meant, so it asks.
    if _a0 == "rsync" and any(t.replace(PH, "") == "--del" or t.replace(PH, "").startswith("--delete") for t in rest):
        ask("rsync --delete removes every destination file the source lacks — confirm the source and destination",
            rule="rsync-delete")

def _run_windows(i):
    while i < len(windows):  # a window's checks may append more (bash -c / eval bodies, find, xargs)
        _check_window(i, windows[i])
        i += 1

def _run_words():
    # GH #382: the queued word windows, and whatever their checks queue, once the token windows are done.
    while _WORDS:
        i = len(windows)
        for depth, ww in _WORDS:
            wc = _drop_ph_tokens(ww)  # a PH-only word is a substitution that may expand to nothing
            for x in ((ww, wc) if wc != ww else (ww,)):
                _WDEPTH[len(windows)] = depth
                windows.append(x)
        del _WORDS[:]
        _WORD_PHASE[0] = True
        try:
            _run_windows(i)
        finally:
            _WORD_PHASE[0] = False

for _b in _SHELL_STDIN_BODIES:  # GH #567: each is a command line, like a sh -c body
    _scan_body(_b)
for _b in _INTERP_HEREDOC_BODIES:  # GH #681: the process-API scan a python -c / node -e body gets (GH #608)
    _ic = _interp_commands(_b) if _PYNODE_PROC_RE.search(_b) else []
    _RM_VIA_INTERP[0] = _RM_VIA_INTERP[0] or bool(_ic)
    for _c in _ic:
        # A whole script holds many literals, most never run: one the tokenizer cannot read (an apostrophe in an
        # argv item, half a quote) is read again with its quotes and backslashes blanked, so its words are still
        # checked; only one that is still unreadable denies, as a -c body's does.
        if _body_readings(_c)[2]:
            _d = re.sub(r"[\"'`\\]", " ", _c)
            _c = _d if not _body_readings(_d)[2] else _c
        _scan_body(_c)
_run_windows(0)

# GH #245: the overlapping spawn scan, last (see _SPAWN_ANCHOR_RES).
if ("agent_id" in d) and (_nested_spawn(cmd, True) or _nested_spawn(cmd, 2)):
    _deny_nested_spawn()
_run_words()

# GH #336: two more readings of the command, as the shell runs it, each checked by every rule above and
# owned by a rule id of its own (so it can ship shadow, GH #337): "ifs-split" reads $IFS / ${IFS} /
# ${IFS:..} as a blank and drops the empty positionals ($9, $@) used as word ends; "var-verb" reads back
# `$NAME` / `${NAME}` where the command assigns NAME a plain value (`X=rm; $X -rf x`; the last value,
# then the first). Views run only after the command passed every check; the var-verb view (rm's rules enforce, GH #767) only
# up to _VIEW_LEN_CAP: each one re-reads the whole text, and a timed-out hook allows.
# ponytail: one substitution per view, not every combination of values or of the two readings.
_IFS_RE = re.compile(r"\$(?:\{IFS(?:[:%#/^,][^}]{0,40})?\}|IFS(?![A-Za-z0-9_]))")
_EMPTY_POS_RE = re.compile(r"\$(?:[1-9@*]|\{[1-9@*]\})")
_VAR_REF_RE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
# NAME=value whose value the text alone gives: '...', "..." without $ ` \, or a bare word without them,
# ended by a blank or a separator. Read from the raw text (bash -c / eval bodies count too), not from the
# tokens: they split `RW=$R/x` into "RW=", "$", "R/x", which reads as RW assigned nothing.
_PLAIN_ASSIGN_RE = re.compile(
    r"(?<![\w$-])([A-Za-z_]\w*)=(?:'([^']*)'|\"([^\"$`\\]*)\"|([^\s;&|()<>'\"$`\\]*))(?=[\s;&|()]|$)")
_VIEW_LEN_CAP = 20_000

# GH #589: a substitution whose output the text shows: `$(echo WORDS)`, `$(printf [--] WORDS)` (also
# `command echo`, `/bin/echo`) and the backtick forms (WORDS with no further substitution in them) print WORDS; `${X:-W}`, `${X-W}`, `${X:=W}`,
# `${X=W}`, `${X:+W}` and `${X+W}` may expand to W. `$(cat list)` prints nothing the text shows.
_ECHO_WORD = r"[ \t]*(?:command[ \t]+)?(?:[^\s()$`/]*/)*(?:echo|printf)"
_LITERAL_SUBST_RE = re.compile(r"\$\(" + _ECHO_WORD + r"((?:[ \t]+[^\s()$`]+)*)[ \t]*\)|`" + _ECHO_WORD
                               + r"((?:[ \t]+[^\s`$]+)*)[ \t]*`")
_DEFAULT_SUBST_RE = re.compile(r"\$\{\w+:?[-=+]([^{}$`]*)\}")

def _default_subst(v, quoted=True):
    # A default goes in as written (`${F:-"-rf"}` -> `"-rf"`, whose quotes the tokenizer then removes, as the
    # shell does), except inside "...": there its unescaped double quotes are dropped (`\"` stays), so it
    # stays part of the outer string (`"${M:-"a && b"}"` is one string to the shell; its `&&` stays quoted).
    # quoted=False leaves a default holding a quote as written (the second, safe copy of the view).
    mask = _quote_mask(v)
    # A quote is escaped only after an odd run of backslashes (`\\"` is a backslash, then a real quote).
    unq = lambda w: re.sub(r'(\\*)"', lambda q: q.group(1) if len(q.group(1)) % 2 == 0 else q.group(0), w)
    def put(e):
        w = e.group(1)
        if not quoted and ('"' in w or "'" in w):
            return e.group(0)
        return unq(w) if mask[e.start()] else w
    return _DEFAULT_SUBST_RE.sub(put, v)

# GH #590: a shell, or source / `.`, whose script is a process substitution printing literal text runs
# that text: `bash <(echo rm -rf build)` and `bash < <(echo ...)` read in the view as `eval rm -rf build`,
# which the eval unwrap scans. The shell name must start a word (`\bash` too), so a long word is not
# rescanned from every position; up to 32 options may come before the script, only a cluster ending in o/O
# (`-o`, `-eo`), --rcfile and --init-file taking a value (`bash -x script.sh <(...)` runs script.sh, so its psub is only an argument).
_PSUB_SCRIPT_RE = re.compile(r"(?<![^\s;&|(){])\\?(?:[^\s;&|()<>]*/)?(?:bash|sh|zsh|dash|ksh|ash|hush|source|\.)"
                             r"(?:[ \t]+(?:[-+][A-Za-z]*[oO][ \t]+[^\s;&|()<>]+|--(?:rcfile|init-file)[ \t]+[^\s;&|()<>]+"
                             r"|[-+][^\s;&|()<>]*)){0,32}?"
                             r"[ \t]+(?:<[ \t]*)?<\(" + _ECHO_WORD + r"((?:[ \t]+[^\s()$`]+)*)[ \t]*\)")

def _psub_eval(e):
    try:
        words = shlex.split(e.group(1))
    except ValueError:
        words = e.group(1).split()
    if words[:1] == ["--"]:
        words = words[1:]
    if words and "%" in words[0]:  # printf's format (`'%s\n'`, `'%s %s\n'`): the text is its arguments
        words = words[1:]
    return "eval " + " ".join(words)

def _literal_subst_words(e):
    words = (e.group(1) or e.group(2) or "").split()
    return " ".join(words[1:] if words[:1] == ["--"] else words)

_SPLIT_ASSIGN_RE = re.compile(r"[A-Za-z_]\w*(?:\[[^\]\s]*\])?\+?=")
_SPLIT_ASSIGN_LEAD = frozenset({"export", "local", "declare", "typeset", "readonly", "then", "do", "else", "elif",
                                "if", "while", "until", "!", "{", "time"})

def _in_assignment_value(text, k, bounds, seps, memo):
    # True when offset k sits in the value of a NAME= / NAME+= / NAME[i]= word in assignment position (statement start,
    # after other assignments, a declaration builtin and its options, or a keyword): bash does not split an
    # assignment's value (GH #767 review 2: `CMD=$(echo 'sudo rm -rf x')` stores text). `env X=$(..)` and
    # `rm --opt=$(..)` are arguments, and do split. bounds (unquoted blanks, separators and line continuations) and
    # seps (the separators) are made once per text, so words are read as the shell splits them (`X='a b' CMD=..`);
    # memo keeps, per statement, how far its words were read and whether all were assignment-position words, so a
    # long chain of glued `NAME=`...`` words is read once, not once per word.
    n = bisect.bisect_left(bounds, k)
    i = bounds[n - 1] + 1 if n else 0
    w = ("word", i)  # the NAME= test once per word: a long \w run before many glued substs (review 7) is read once
    if w not in memo:
        memo[w] = bool(_SPLIT_ASSIGN_RE.match(text, i))
    if not memo[w]:
        return False
    m = bisect.bisect_left(seps, i)
    j = seps[m - 1] + 1 if m else 0
    a, ok = memo.get(j, (bisect.bisect_left(bounds, j), True))
    start = bounds[a - 1] + 1 if a and bounds[a - 1] >= j else j
    while ok and a < n:
        t = text[start:bounds[a]]
        if t and t != "\\" and not (t in _SPLIT_ASSIGN_LEAD or _SPLIT_ASSIGN_RE.match(t)
                                     or (t[:1] == "-" and t[1:].isalnum())):
            ok = False
        start = bounds[a] + 1
        a += 1
    memo[j] = (a, ok)
    return ok

def _literal_subst_split(text):
    # GH #718: the shell splits an unquoted $(...)'s output into words, so `rm $(echo ' -rf') b` is rm -rf b, which
    # the plain rewrite (echo's arguments as written) does not show. This copy is only for a substitution that starts
    # a word (after a blank or a separator, so not `''$(..)` or `"$(..)"`); each output word is escaped whole, so it
    # only shows a flag the quotes hid and builds no syntax (`x; rm -rf /` stays text). Additive: the plain copy stays.
    mask = _quote_mask(text)
    def sub(e):
        # Inside '...' the text is data (review 3: an escaped ' from the output closed it in the view).
        if mask[e.start()] or (e.start() and text[e.start() - 1] not in " \t\n;&|("):
            return e.group(0)
        raw = e.group(1) or e.group(2) or ""
        try:
            words = shlex.split(raw)
        except ValueError:
            return e.group(0)
        out = " ".join(words[1:] if words[:1] == ["--"] else words).split()
        return " ".join(re.sub(r"""([^\w./=:@%+,-])""", r"\\\1", w) for w in out)
    return _LITERAL_SUBST_RE.sub(sub, text)

def _split_bounds(text, mask):
    # The offsets of the unquoted blanks and separators outside $(...) and `...` (GH #767 review 5: `TS=$(date +%s)`
    # is one word, and its ( starts no statement), and of each line continuation (a blank); seps are the separators.
    bounds, seps, depth, tick, i, n = [], [], 0, False, 0, len(text)
    while i < n:
        c = text[i]
        if mask[i]:
            if c == "\n" and i and text[i - 1] == "\\" and not depth and not tick:
                bounds.append(i)
        elif c == "`":
            tick = not tick
        elif c == "(" and i and text[i - 1] == "$":  # _quote_mask leaves a "$(" in "..." unquoted from its (
            depth += 1
        elif c == ")" and depth:
            depth -= 1
        elif not depth and not tick and c in " \t\n;&|(":
            bounds.append(i)
            if c not in " \t":
                seps.append(i)
        i += 1
    return bounds, seps

def _literal_subst_glued(text):
    # GH #767: one more copy for a substitution glued to the word before it (`x$(..)`, `\ $(..)`, `'a'$(..)`): bash
    # glues the output's first word to that word and splits off the rest (`rm \ $(echo 'x -rf') b` is rm ' x' -rf b;
    # a leading blank makes that first word empty). A backslash-newline before it is a line continuation, and an
    # assignment's value is not split. Its own copy, so _literal_subst_split's copy, and every deny it gives, stays
    # as it was (review 4: splitting a glued `Y=..` in that copy hid the rm after it).
    mask = _quote_mask(text)
    bounds, seps = _split_bounds(text, mask)
    memo = {}
    esc = lambda w: re.sub(r"""([^\w./=:@%+,-])""", r"\\\1", w)
    def sub(e):
        k = e.start()
        if mask[k] or not k:
            return e.group(0)
        j = k - 1
        while j > 0 and text[j - 1] == "\\":  # the backslashes before that char: an odd run escapes it
            j -= 1
        if text[k - 1] in " \t\n;&|(" and not ((k - 1 - j) % 2 and text[k - 1] != "\n"):
            return e.group(0)  # not glued: _literal_subst_split's copy reads it
        raw = e.group(1) or e.group(2) or ""
        try:
            words = shlex.split(raw)
        except ValueError:
            return e.group(0)
        words = words[1:] if words[:1] == ["--"] else words
        if words and "%" in words[0] and "printf" in e.group(0)[:e.group(0).find(raw) if raw else None]:
            words = words[1:]  # printf's format is not output (review 6: `-b rel-$(printf '%s' 2026)` is one word)
        out = " ".join(words)
        if not re.search(r"\s", out) or _in_assignment_value(text, k, bounds, seps, memo):
            return e.group(0)
        first, rest = ("", out) if out[:1].isspace() else (out.split(None, 1) + [""])[:2]
        return esc(first) + " " + " ".join(esc(w) for w in rest.split())
    return _LITERAL_SUBST_RE.sub(sub, text)

def _ifs_split(text):
    return _EMPTY_POS_RE.sub("", _IFS_RE.sub(" ", text)) if "IFS" in text else text

def _subst_literals(text, glued=True):
    # The text with each literal substitution replaced by what it prints: one copy per quoted mode (see below).
    out = []
    if "$" in text or "`" in text or "<(" in text:
        for quoted in (True, False):
            v = text
            for _ in range(3):  # inside out: `${X:-${Y:--rf}}`, `$(echo $(echo -rf))`
                w = _default_subst(_LITERAL_SUBST_RE.sub(_literal_subst_words, _PSUB_SCRIPT_RE.sub(_psub_eval, v)), quoted)
                if w == v:
                    break
                v = w
            if v != text and v not in out:
                out.append(v)
        if ("'" in text or '"' in text or "\\" in text) and _LITERAL_SUBST_RE.search(text):
            # GH #767 review 5: brace-view's copies (glued=False) run before the subst-literal views and share their
            # positional-fill budget, so the glued copy is read only here, after develop's copies.
            for v in (_literal_subst_split(text),) + ((_literal_subst_glued(text),) if glued else ()):
                if v != text and v not in out:
                    out.append(v)
    return out

def _literal_dollars(text, comments=False):
    # The offsets of each $ the shell keeps as text: inside '...' (outside "...") or after an odd run of
    # backslashes. var-verb puts no value back there (GH #767 review 6: `rm '$F' x` removes a file named $F).
    # comments (GH #810): also skip `#` comments, whose `'` opens no quote (`| # it's fed` then `$X`). Read only by one
    # extra var-verb copy (_views), never in place of develop's reading: a misread comment (`\ #` is none in bash)
    # can put a value inside a real '...' and hide a deny (GH #812 reviews 10-11).
    return _literal_dollars_read(text, comments)

def _literal_dollars_read(text, comments):
    out, sq, dq, i, n = set(), False, False, 0, len(text)
    while i < n:
        c = text[i]
        if sq:
            if c == "'":
                sq = False
            elif c == "$":
                out.add(i)
        elif c == "\\":
            if text[i + 1:i + 2] == "$":
                out.add(i + 1)
            i += 1
        elif c == "'" and not dq:
            sq = True
        elif c == '"':
            dq = not dq
        elif comments and c == "#" and not dq and (i == 0 or text[i - 1] in " \t\n;&|()"):
            # GH #810: a comment, to its line end: its `'` opens no quote (`| # it's fed` then `$X`)
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        i += 1
    return out

def _views():
    out = []
    # GH #309: the command with every brace group expanded as the shell does. Shadow first (GH #337):
    # drop "brace-view" from SHADOW_RULES once /mh:gate-report shows no false positive.
    # GH #690: bash expands braces before $IFS splitting and command substitution, so a verb or flag that
    # needs both (`r{m,m}${IFS}-rf b`, `rm $(echo --{r,f}) b`) is read by brace-view copies of the expanded
    # text with both rewrites applied (each only turns text into the words it stands for, so one copy per
    # quoted mode reads all that either rewrite alone would); they enforce what brace-view enforces.
    if _BRACEX_TEXT is not None:
        out.append(("brace-view", _BRACEX_TEXT))
        ifs = _ifs_split(_BRACEX_TEXT)
        for v in _subst_literals(ifs, glued=False) or [ifs]:
            if v != _BRACEX_TEXT and ("brace-view", v) not in out:
                out.append(("brace-view", v))
    # The enforced ifs-split view reads as far as the parser does (_CMD_LEN_CAP); capping it lower let
    # padding past _VIEW_LEN_CAP hide `rm${IFS}-rf`. Only the var-verb view keeps the lower cap (GH #787 tracks raising it now rm enforces there).
    v = _ifs_split(cmd)
    if v != cmd:
        out.append(("ifs-split", v))
    # GH #589: the command with each literal substitution replaced by what it prints. Enforced, and read as
    # far as the parser does, like ifs-split (a substitution in rm's flags hid `-rf` from every rule).
    # A second copy leaves every quoted default as written: a view whose quotes do not balance is dropped
    # unread, so a misread quoted default must not hide an unquoted one (`${G:--rf}`) in the same command.
    for v in _subst_literals(cmd):
        out.append(("subst-literal", v))
    if len(cmd) > _VIEW_LEN_CAP:
        return out
    vals = {}
    for m in _PLAIN_ASSIGN_RE.finditer(cmd):
        vals.setdefault(m.group(1), []).append(next(g for g in m.groups()[1:] if g is not None))
    lit = _literal_dollars(cmd) if vals else ()
    # GH #798 review: four copies: the last value (a loop's later pass or a function called after the assignment:
    # `F=-i; for ..; do rm $F b; F=-rf; done`), the first value, each value in order (the one assigned last before
    # the reference, else the last value), and "raw". Only the in-order copy is spawn-scanned (_VAR_SPAWN_TEXTS): the
    # first-value copy made `BIN=claude .. BIN=python3; $BIN -c ..` a spawn, the last-value one `BIN=python3; $BIN -c ..;
    # BIN=claude; command -v $BIN` (review 5). The raw copy is in order with a reference that has no assignment
    # before it left as written, as bash expands it to nothing: `F=-r; rm $F $G b; G=-i` does not prompt, while the
    # in-order copy's last-value fallback read it as -i (GH #805); it also drops an unset, subshell or prefix value
    # (GH #808). A fifth, scoped copy (GH #818) is the raw one that also reads a background list, a function body, a
    # `local` and a loop's later pass as bash scopes them. rm's rules read all five; the spawn scan only the in-order one.
    for pick in (-1, 0, None, "raw", "scoped"):
        def _sub(m, pick=pick):
            name = m.group(1) or m.group(2)
            return vals[name][pick] if name in vals and m.start() not in lit else m.group(0)
        v = (_ordered_var_text(cmd, pick is None, scoped=pick == "scoped") if pick in (None, "raw", "scoped")
             else _VAR_REF_RE.sub(_sub, cmd)) if vals else cmd
        if pick is None and v != cmd:
            _VAR_SPAWN_TEXTS.add(v)
        if v != cmd and ("var-verb", v) not in out:
            out.append(("var-verb", v))
    if vals and "#" in cmd:
        # GH #810: one more in-order copy that reads `#` comments as bash does, so `echo hi | # it's fed` then `$X` puts
        # claude back; an extra copy, so a misread comment only adds a reading (GH #812 review 11).
        v = _ordered_var_text(cmd, True, comments=True)
        if v != cmd and ("var-verb", v) not in out:
            _VAR_SPAWN_TEXTS.add(v)
            out.append(("var-verb", v))
    return out

def _view_windows(text):
    # A body that blew the depth budget ended the previous view with the flag still set; it says nothing
    # about this view's text, and read as this view's own blow-out it dropped the view unread.
    _DEPTH_BUDGET_BLOWN[0] = False
    _XARGS_HANDOVERS[0] = 0  # the 50-handover bound is per reading: the main reading spent its own
    try:
        toks = _tokens(_blanked(text))
    except ValueError:
        return []  # a value that unbalances a quote: the view is not a command
    if _DEPTH_BUDGET_BLOWN[0]:
        _DEPTH_BUDGET_BLOWN[0] = False
        return []
    out = []
    for cur, ww in _readings(toks):
        if ww:
            _queue_words(ww, 0)
        if not cur:
            continue
        out.append(cur)
        curc = _drop_ph_tokens(cur)
        if curc != cur:
            out.append(curc)
    return out

# GH #593: `${CMD} build` reaches argv0 as PH, which no window can tie back to CMD. A reading with each
# `${NAME...}` written as `$NAME` (inside out, so `${PY:-${HOME}/py}` is `$PY`) runs every window check
# with only the opaque-var-verb ask live, so the braced form asks wherever `$CMD` would (sudo, bash -c,
# time). Nothing else: a default rewritten away must not change what another rule reads.
_BRACED_REF_RE = re.compile(r"\$\{([A-Za-z_]\w*)(?:[:\-=+?%#/^,\[][^{}]*)?\}")
def _braced_reading():
    v = cmd
    for _ in range(3):
        w = _BRACED_REF_RE.sub(lambda m: "$" + m.group(1), v)
        if w == v:
            break
        v = w
    if v == cmd:
        return
    # Its windows stay in `windows`, so the views after it append past them and no index-keyed state
    # (_WDEPTH, _ENV_PRE570_WINDOWS) is read by a later window; _RM_VIA_INTERP is put back.
    start = len(windows)
    rm_via_interp = _RM_VIA_INTERP[0]
    _ONLY_RULE[0] = frozenset({"opaque-var-verb"})
    try:
        windows.extend(_view_windows(v))
        i = start
        while i < len(windows) and not _ASKED and ("opaque-var-verb", "ask") not in _SHADOW_LOGGED:
            try:
                _check_window(i, windows[i])
            except _ViewStop:
                pass
            i += 1
    finally:
        _ONLY_RULE[0] = None
        _RM_VIA_INTERP[0] = rm_via_interp
        del _WORDS[:]  # the reading's queued words: the main reading ran its own
if "${" in cmd and len(cmd) <= _VIEW_LEN_CAP:
    _braced_reading()

def _enforced_pass(text):
    # GH #661: a shadowed view stops at its first hit, so a rule it enforces (_VIEW_ENFORCED) may not have read
    # the windows after that hit (`fi{nd,nd} x -delete; rm --{r,f} b`). This pass reads every window once more
    # with only those rules live; any other rule's deny ends that window alone.
    # Another rule's deny passes on (_ONLY_RULE_PASS_ON) so the enforced rule later in the same window still
    # runs; code written to stop at a deny may then fail, which only skips that window. The first pass marked
    # the view's word windows seen, so they are cleared to be queued again.
    # The pass reads only the _VIEW_ENFORCED rules, so it runs no spawn scan (_scan_body, _deny_nested_spawn): that scan's
    # budget, spent a second time on the expanded text, denied large legal subagent bodies, let one costly
    # expansion hide an rm, or ran the gate near the hook timeout (reviews 4-8). A spawn is the main reading's.
    _ONLY_RULE[0], _ONLY_RULE_PASS_ON[0] = _VIEW_ENFORCED[_VIEW[0]], True
    try:
        _WORDS_SEEN.clear()
        i = len(windows)
        windows.extend(_view_windows(text))
        while True:
            while i < len(windows):  # a window's checks may append more (bash -c bodies, xargs, find)
                try:
                    _check_window(i, windows[i])
                except (_ViewStop, Exception):  # never SystemExit: an enforced deny exits as it should
                    pass
                i += 1
            if not _WORDS:
                break
            for depth, ww in _WORDS[:]:  # the word windows, as _run_words reads them (in the word phase)
                wc = _drop_ph_tokens(ww)
                for x in ((ww, wc) if wc != ww else (ww,)):
                    _WDEPTH[len(windows)] = depth
                    windows.append(x)
            del _WORDS[:]
            _WORD_PHASE[0] = True
    finally:
        _ONLY_RULE[0], _ONLY_RULE_PASS_ON[0], _WORD_PHASE[0] = None, False, False
        del _WORDS[:]

_CMD_STATEMENTS = None
_VIEW_STATEMENTS_SCANNED = set()

def _view_spawn_statements(text):
    # GH #798: the statements of a view's text that the command or a body the main reading scanned does not hold as
    # written (those were scanned whole), each once across the views. Statement by statement, not one span: a change
    # near each end of a script made the span the whole script, and the views' budget refused 6 KB scripts (review).
    global _CMD_STATEMENTS
    if _CMD_STATEMENTS is None:
        _CMD_STATEMENTS = set(_text_statements(cmd))
    out = []
    for st in _text_statements(text):
        if st.strip() and st not in _CMD_STATEMENTS and st not in _MAIN_STATEMENTS and st not in _VIEW_STATEMENTS_SCANNED:
            _VIEW_STATEMENTS_SCANNED.add(st)
            out.append(st)
    return out

def _scan_view_statements(text):
    # A spawn in a statement only a view reads denies (_deny_nested_spawn exits; in a view a rule-less deny() only
    # ended the view, so `bash${IFS}-c 'claude -p x'` and `X=claude; bash -c "$X -p x"` passed).
    for st in _view_spawn_statements(text):
        if _nested_spawn(st, False) or _nested_spawn(st, True) or _nested_spawn(st, 2) or _subst_spawn(st):
            _deny_nested_spawn()

_UNSET_RE = re.compile(r"(?<![\w$-])unset((?:[ \t]+-[A-Za-z]*-?)*)((?:[ \t]+[A-Za-z_]\w*)+)")
_UNSET_MORE_RE = re.compile(
    r"(?<![\w$-])unset((?:[ \t]+-[A-Za-z]*-?)*)((?:[ \t]+(?:'[A-Za-z_]\w*'|\"[A-Za-z_]\w*\"|\$\{?[A-Za-z_]\w*\}?|[A-Za-z_]\w*)"
    r"(?=[\s;&|)]|$))+)")
_UNSET_WORD_RE = re.compile(r"'([A-Za-z_]\w*)'|\"([A-Za-z_]\w*)\"|\$\{?[A-Za-z_]\w*\}?|([A-Za-z_]\w*)")
_LOCAL_RE = re.compile(r"(?<![\w$-])(local|declare|typeset)((?:[ \t]+[-+][A-Za-z]*)*)((?:[ \t]+[A-Za-z_]\w*(?=[\s;&|)]|$))+)")
_DECL_WORDS = frozenset(("export", "local", "declare", "typeset", "readonly"))
_REDIR_RE = re.compile(r"[0-9]*(?:[<>]&?|&>)>?-?[ \t]*(?:[^\s;&|()<>]+)?")

# A call the text does not name: eval, an expansion joined to a word (`x_$y`, `${y}_x`, `"a"b`), or a command word that
# starts with an expansion (`"$fn"`, `$(get)`; GH #818 review 10).
_DYN_CALL_RE = re.compile(r"(?<![\w$-])eval(?![\w-])|[\w-]['\"]?\$\{?[A-Za-z_]|\w['\"]\w|\}['\"]?[\w-]"
                          r"|(?:^|[;&|(){}\n`]|(?<![\w-])(?:then|do|else|elif|if|while|until|!))[ \t]*['\"]?\$", re.M)
_LOOP_KW_RE = re.compile(r"(?<![\w$-])(for|while|until|select)(?![\w-])")
_NOUNSET_RE = re.compile(r"(?<![\w-])set[ \t]+(?:-[A-Za-z]*u|-o[ \t]+nounset)")
_FN_ANY_HEAD_RE = re.compile(r"(?<![\w.:$-])(?:function[ \t]+[^\s()<>;&|]+|[A-Za-z_][\w.:-]*[ \t]*\([ \t]*\))")
_FN_HEAD_RE = re.compile(r"(?:(?<![\w-])function[ \t]+([^\s()<>;&|]+)(?:[ \t]*\([ \t]*\))?|([A-Za-z_][\w.:-]*)[ \t]*\([ \t]*\))[ \t\n]*$")

def _cmd_pos(text, i, seps=";\n&|(){"):
    # True when offset i starts a command word: after a separator (or `f()`), at the start, or after do/then/else.
    j = i - 1
    while j >= 0 and text[j] in " \t":
        j -= 1
    if j < 0 or text[j] in seps:
        return True
    return re.search(r"(?:^|[\s;&|()])(?:do|then|else)$", text[max(0, j - 5):j + 1]) is not None

def _shell_scan(text, groups=None):
    # (spans, text_at): spans are the (open, close) offsets of each ( .. ) outside quotes and comments, $( .. ) and
    # <( .. ) included, as a value set inside one never reaches the text after it closes (a `)` with nothing open, a
    # case pattern, closes nothing); text_at[i] is 1 where offset i is quoted or in a comment, so a word there is text.
    # GH #818: a list run in the background (`G=-i & ..`, `{ ..; } &`) is a subshell too, so it is a span from the
    # separator before it to its `&`, in groups["bg"] (groups is a dict). groups["fn"] gets (open, close, name, head) for each function
    # body `name() { .. }` / `function name { .. }` and groups["loop"] (open, close, keyword, keyword offset) for each
    # `do .. done`.
    spans, stack, sq, dq, i, n = [], [], False, False, 0, len(text)
    text_at = bytearray(n)
    seg, braces, loops = [-1], [], []
    fns, loop_spans = [], []
    exp, bt, brk = 0, False, 0  # inside ${..}, backticks, $[..] / [..]: an `&` there is text (GH #818 review)
    bg, dq_sub, brace_bad = [], False, False
    while i < n:
        c = text[i]
        if sq:
            text_at[i] = 1
            sq = c != "'"
        elif c == "\\":
            text_at[i:i + 2] = b"\1" * len(text_at[i:i + 2])
            i += 1
        elif c == "'" and not dq:
            text_at[i], sq = 1, True
        elif c == '"':
            text_at[i], dq = 1, not dq
        elif dq:
            text_at[i] = 1
            if c == "`" or (c == "$" and text[i + 1:i + 2] == "("):
                dq_sub = True
            elif c == "$" and text[i + 1:i + 2] == "{":
                j = text.find("}", i)
                dq_sub = dq_sub or j < 0 or '"' in text[i:j]  # "${X:-"a & b"}": its inner quotes
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            j = text.find("\n", i)
            j = n if j < 0 else j
            text_at[i:j] = b"\1" * (j - i)
            i = j
            continue
        elif c == "$" and text[i + 1:i + 2] == "{":
            exp += 1
            i += 1
        elif c == "}" and exp:
            exp -= 1
        elif c == "`":
            bt = not bt
        elif c == "[":
            brk += 1
        elif c == "]" and brk:
            brk -= 1
        elif c == "(":
            stack.append(i)
            seg.append(i)
        elif c == ")" and stack:
            spans.append((stack.pop(), i))
            if len(seg) > 1:
                seg.pop()
        elif c in ";\n":
            seg[-1] = i
        elif c == "&":
            if text[i + 1:i + 2] == "&":
                i += 1
            elif not (i and text[i - 1] in "<>|;") and text[i + 1:i + 2] != ">" and not (exp or bt or brk):
                bg.append((seg[-1], i))  # GH #818: the list before a lone `&` runs in a subshell
                seg[-1] = i
        elif c in "{}d" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            w = re.match(r"(?:\{|\}|done|do)(?=[\s;&|)<>]|$)", text[i:i + 5])
            w = w and w.group(0)
            if w == "{" and text[i + 1:i + 2].isspace() and (_cmd_pos(text, i) or _FN_HEAD_RE.search(text, max(0, i - 200), i)):
                f = _FN_HEAD_RE.search(text, max(0, i - 200), i)
                braces.append((i, seg[-1], f and (f.group(1) or f.group(2), f.start())))
            elif w == "}" and braces and _cmd_pos(text, i, ";\n&"):
                o, seg[-1], name = braces.pop()  # the group's list goes on past it: `{ ..; } &` is one background list
                if name:
                    fns.append((o, i, name[0], name[1]))
            elif w == "}":
                brace_bad = True  # a `}` the scan did not match (`fi }`, `) }`)
            elif w == "do" and _cmd_pos(text, i, ";\n&"):
                kw = None
                for kw in _LOOP_KW_RE.finditer(text, max(0, i - 2000), i):
                    pass
                loops.append((i, seg[-1], kw and kw.group(1), kw.start() if kw else i))
            elif w == "done" and loops and _cmd_pos(text, i, ";\n&"):
                o, seg[-1], kw, head = loops.pop()
                loop_spans.append((o, i, kw, head))
        i += 1
    if groups is not None:
        groups["fn"], groups["loop"] = fns, loop_spans
        # GH #818 review 6: every function head has a body the scan recorded (not `f() ( .. )`, a `}` right after `fi`,
        # or a comment before the `{`), else the function rule is off.
        heads = sum(1 for m in _FN_ANY_HEAD_RE.finditer(text) if not text_at[m.start()])
        # GH #818 review 7: nor with a call the text does not name (`setup_$mode`, `"set"up`, eval).
        groups["fn_ok"] = not braces and not brace_bad and heads == len(fns) and not _DYN_CALL_RE.search(text)
    # GH #818 review 2/3: the scan does not follow the quotes nested in "$( .. )", "` .. `" or "${X:-".."}", where an inner "a & b" read
    # as a bare `&`; with one in the text no background list is read, as before GH #818.
    if groups is not None:
        groups["bg"] = [] if dq_sub else bg
    return spans, text_at

def _prefix_assign(text, m, memo):
    # True when the assignment is a prefix on a command (`G=-i rm $G b`): bash expands that command's words before the
    # temporary value applies, and it is gone after, so nothing reads it. A chain of assignments with no command after
    # it (`G=-i F=-r;`, redirections such as `F=-r 2>/dev/null;` included) persists, as do the arguments of
    # export/local/declare/typeset/readonly. memo maps each chain offset walked to the answer, so a long chain is
    # walked once, not once per assignment in it.
    k, seen, out = m.end(), [], None
    while out is None:
        if k in memo:
            out = memo[k]
            break
        seen.append(k)
        j = k
        while k < len(text) and text[k] in " \t":
            k += 1
        if k == len(text) or text[k] in ";&|()\n#}" or (k == j and text[k] not in "<>"):
            out = False
            break
        nxt = _PLAIN_ASSIGN_RE.match(text, k) or _REDIR_RE.match(text, k)
        if nxt is None or nxt.end() == k:
            head = re.split(r"[;&|(){}\n]", text[:m.start()])[-1].split()
            out = not any(w in _DECL_WORDS for w in head)
            break
        if nxt.re is _PLAIN_ASSIGN_RE:
            m = nxt
        k = nxt.end()
    for k in seen:
        memo[k] = out
    return out

class _SlowCopy(Exception):
    pass

_MAY_SET_RE = re.compile(r"(?<![\w$-])(?:source|\.|eval)[ \t]")
_LOOP_STOP_RE = re.compile(r"(?<![\w$-])(?:break|continue|return|exit)(?![\w-])")

_OPERATOR_CHARS = re.compile(r"[|;&<>()\n`]")

def _ordered_var_text(text, fallback_last=True, outer=None, plain_only=False, comments=False, scoped=False):
    # GH #798 review: each $NAME / ${NAME} read as the plain value assigned to NAME most recently before it, so
    # `BIN=claude; .. BIN=python3; $BIN -c ..` is python3 while `X=claude; $X -p x` is claude. Order-aware, not
    # scope-aware: a function's or a subshell's value counts from where it is written. A reference with no assignment
    # before it reads the last value, or with fallback_last false is left as written (GH #805).
    # GH #808: with fallback_last false (the raw copy) a value bash never expands at the reference is dropped too: one
    # `unset` since (left as written, as bash expands it to nothing), one set in a subshell that closed before it, and a
    # prefix assignment on a command. Dropping only ever leaves a reference as written, so this copy reads more -r, not less.
    raw = not fallback_last
    # GH #818: scoped (with raw) is one more copy that also reads the shapes below as bash scopes them; the raw copy
    # without it stays as it was, so this copy only adds a reading.
    scoped = raw and scoped
    memo = {}
    sets = [(m.end(), m.group(1), next(g for g in m.groups()[1:] if g is not None))
            for m in _PLAIN_ASSIGN_RE.finditer(text) if not (raw and _prefix_assign(text, m, memo))]
    groups = {"fn": (), "loop": (), "bg": (), "fn_ok": False}
    spans, text_at = _shell_scan(text, groups if scoped else None) if raw else ((), b"")
    scope = {}  # GH #818: an entry's end -> the (open, close) only references inside which it reaches
    no_cmd = set()  # GH #818 review 10: an unset that is no command (`kubectl config unset G`), for the loop rule
    if raw:
        for m in _UNSET_RE.finditer(text):
            if "f" not in m.group(1) and not text_at[m.start()]:
                base = m.start(2)
                ok = not scoped or _cmd_pos(text, m.start())
                for w in re.finditer(r"[A-Za-z_]\w*", m.group(2)):
                    sets.append((base + w.end(), w.group(0), None))
                    if not ok:
                        no_cmd.add(base + w.end())
        # GH #818: a quoted name (`unset 'G'`) or one after an expansion (`unset ${X} G`).
        for m in _UNSET_MORE_RE.finditer(text) if scoped else ():
            if "f" not in m.group(1) and not text_at[m.start()] and _cmd_pos(text, m.start()):
                base = m.start(2)
                for w in _UNSET_WORD_RE.finditer(m.group(2)):
                    if w.group(1) or w.group(2) or w.group(3):
                        sets.append((base + w.end(), w.group(1) or w.group(2) or w.group(3), None))
        # GH #818: `local G` / `declare G` with no value, inside a function: G is unset there, for that body only.
        locs = list(_LOCAL_RE.finditer(text)) if scoped and not _NOUNSET_RE.search(text) else ()
        for m in locs if len(locs) <= 200 else ():  # GH #818 review 6: a bound, as each one searches its body
            if not text_at[m.start()] and not set(m.group(2)) & set("gpfFnI") and _cmd_pos(text, m.start()):
                body = min(((o, c) for o, c, _, _ in groups["fn"] if o < m.start() < c), key=lambda b: b[1] - b[0],
                           default=None)
                if body:
                    base = m.start(3)
                    for w in re.finditer(r"[A-Za-z_]\w*", m.group(3)):
                        if re.search(r"(?<![\w$-])" + w.group(0) + "=", text[body[0]:m.start()]):
                            continue  # GH #818 review 5/6: set in the body before, maybe local, which a bare `local` keeps
                        scope[base + w.end()] = body
                        sets.append((base + w.end(), w.group(0), None))
    sets.sort(key=lambda e: e[0])
    if not sets and not outer:
        return text
    lit, by_name = _literal_dollars(text, comments), {}
    for e, n, v in sets:  # per name, in order: the latest one before a reference is a bisect (GH #812 review 10)
        by_name.setdefault(n, ([], []))
        by_name[n][0].append(e)
        by_name[n][1].append(v)
    first_call, enclosing, work, slow = {}, {}, [0], [not scoped]
    nounset = scoped and _NOUNSET_RE.search(text) is not None  # GH #818 review 9: an unset G aborts bash there
    fn_call_re = re.compile(r"(?<![\w.:$-])(?:" + "|".join(sorted({re.escape(f[2]) for f in groups["fn"]})) + r")(?![\w.:-])"
                            ) if groups["fn"] else None
    stops, sets_memo = {}, {}
    def loop_stops(a, b):
        if (a, b) not in stops:
            spend(b - a)
            stops[(a, b)] = _LOOP_STOP_RE.search(text, a, b) is not None
        return stops[(a, b)]
    def cond_reads(name, a, b):
        if (name, a, b, 0) not in sets_memo:
            spend(b - a)
            sets_memo[(name, a, b, 0)] = re.search(
                r"\$\{?[#!]?" + name + r"(?![\w])|-v[ \t]+['\"]?" + name + r"(?![\w])", text[a:b]) is not None
        return sets_memo[(name, a, b, 0)]
    def may_set(name, a, b):
        if (name, a, b) not in sets_memo:
            sets_memo[(name, a, b)] = _may_set(name, a, b)
        return sets_memo[(name, a, b)]
    def _may_set(name, a, b):
        # GH #818 review 7: text between a and b that may set name: a call to a function (bash's dynamic scope lets it
        # fill a caller's local), source / . / eval, or any NAME=, NAME+=, read/mapfile/getopts/printf -v/for NAME.
        spend(b - a)
        t = text[a:b]
        return not groups["fn_ok"] or bool(
            (fn_call_re and fn_call_re.search(t)) or _MAY_SET_RE.search(t) or re.search(
                r"(?<![\w$-])" + name + r"\+?=|\$\{" + name + r":?=|(?<![\w-])(?:read|mapfile|readarray|getopts|for)(?![\w-])"
                r"[^;&|\n]*(?<![\w$-])" + name + r"(?![\w-])|-v[ \t]+" + name + r"(?![\w-])", t))
    def spend(n):
        # GH #818 review 2: past one budget the scoped copy is read as the raw one (paren subshells only, no background
        # list, function or loop rule), which then adds nothing.
        if slow[0]:
            return
        work[0] += n
        if work[0] > 100_000:
            raise _SlowCopy
    def encl(at):
        # The spans and function bodies holding an entry, once per entry (GH #818 review: per reference was slow).
        if slow[0]:
            return [(o, c) for o, c in spans if o < at <= c], (), ()
        if at not in enclosing:
            spend(len(spans) + len(groups["bg"]) + len(groups["fn"]))
            fl = []
            for o, c, name, head in groups["fn"]:
                if o < at < c:
                    if (o, name) not in first_call:
                        # GH #818: a body's value reaches a reference outside it once its name is written as a word
                        # anywhere outside its own definition before the reference (`main(){ init; }; init(){ G=x; }; main`),
                        # quoted or not.
                        first_call[(o, name)] = next(
                            (w.start() for w in re.finditer(r"(?<![\w.:-])" + re.escape(name) + r"(?![\w.:-])", text)
                             if not head <= w.start() <= c), len(text))
                    fl.append((o, c, first_call[(o, name)]))
            enclosing[at] = ([(o, c) for o, c in spans if o < at <= c], [(o, c) for o, c in groups["bg"] if o < at <= c], fl)
        return enclosing[at]
    def usable(at, v, ref, strict=False, name=None):
        sp, bg, fl = encl(at)
        if not slow[0]:
            spend(1 + len(sp) + len(bg) + len(fl))
        if any(not o < ref < c for o, c in sp):
            return False  # set inside a subshell the reference is not in
        if (v is not None or strict) and any(not o < ref < c for o, c in bg):
            return False  # GH #818: a value set in a background list; an unset there still counts, as develop read it
        if strict and v is None and at in no_cmd:
            return False
        sc = scope.get(at)
        if sc and (slow[0] or not sc[0] < ref < sc[1] or (at < ref and may_set(name, at, ref))):
            return False
        # A value in a function body only once a call is written; an unset too for the loop rule (strict), never in
        # the walk-back below, so an unset reads as develop read it.
        # GH #818 review 5: a reference inside a body runs when that body is called, which the text order does not
        # show (functions first, calls at the bottom), so the rule reads only a reference outside every body.
        return (v is None and not strict) or not fl or not groups["fn_ok"] or in_body(ref) or all(
            o < ref < c or first < ref for o, c, first in fl)
    def in_body(ref):
        return any(o < ref < c for o, c, _, _ in groups["fn"])
    def sub(m):
        r = pick(m)
        # plain_only (GH #812 review 3): a value holding an operator char is left as written: an expanded `|` is no
        # pipe (`PAT="error|claude"; grep -E $PAT log`).
        return m.group(0) if plain_only and _OPERATOR_CHARS.search(r) else r
    def pick(m):
        name = m.group(1) or m.group(2)
        if m.start() in lit:
            return m.group(0)
        if name in by_name:  # the latest assignment before it by bisect, past any set in a closed subshell (GH #808)
            ends, vals = by_name[name]
            ref = m.start()
            if groups["loop"] and not slow[0]:
                spend(len(groups["loop"]))
            for lo, lc, kw, head in groups["loop"] if not nounset else ():
                # GH #818: a later pass of a loop the reference is in reads the body's last entry after it when the body
                # sets nothing before it: an unset there leaves the reference as written. Review 9: a while/until
                # condition runs before each pass, so the scans start at the loop's keyword, and one that reads G may end
                # the loop once G is unset.
                if lo < ref < lc and not slow[0] and (kw == "for" or kw in ("while", "until") and not cond_reads(
                        name, head, lo)) and not loop_stops(head, lc) and not may_set(name, head, lc):
                    ks = range(bisect.bisect_right(ends, lo), bisect.bisect_left(ends, lc))
                    first = next((k for k in ks if usable(ends[k], vals[k], ref, True, name)), None)
                    if first is not None and ends[first] > ref:
                        lk = next(k for k in reversed(ks) if usable(ends[k], vals[k], ref, True, name))
                        if vals[lk] is None:
                            return m.group(0)
            skip = []
            for k in range(bisect.bisect_right(ends, ref) - 1, -1, -1):
                at = ends[k]
                if skip and any(o < at <= c for o, c in skip):
                    continue  # GH #818 review 8: in a scope a later value of it was dropped for, an unset too
                if usable(at, vals[k], ref, name=name):
                    return m.group(0) if vals[k] is None else vals[k]
                if vals[k] is not None and not slow[0]:
                    _, bg, fl = encl(at)
                    skip += [(o, c) for o, c in bg if not o < ref < c]
                    if groups["fn_ok"] and not in_body(ref):
                        skip += [(o, c) for o, c, first in fl if not (o < ref < c or first < ref)]
        # No assignment before it: a loop's later pass or a function called after the assignment reads the last
        # value (`g(){ $X -p x; }; X=claude; g`).
        # A body's outer value (GH #812: its environment) comes before its own later one.
        if outer and name in outer:
            return outer[name]
        return last.get(name, m.group(0)) if fallback_last else m.group(0)
    last = {n: v for _, n, v in sets if v is not None}
    try:
        return _VAR_REF_RE.sub(sub, text)
    except _SlowCopy:
        slow[0] = True
        return _VAR_REF_RE.sub(sub, text)

_CMD_VALS = None
_NESTED_VALS = {}  # GH #816: the bodies' own plain assignments, read only by the unescaped copies
_BODY_VAR_WORK, _BODY_VAR_BUDGET = 0, 300_000  # characters substituted, summed over every body and pass

def _scan_body_vars(body, unescaped=False):
    # GH #812 / #810 item 2: a body is a script of its own, so its $NAME reads, in order, the plain value the body
    # assigns before it (`bash -c 'X=claude; $X -p x'`), else the outer command's last one (the child's environment:
    # `export X=claude; bash -c '$X -p x'`), else the body's last. A single-quoted body hid both from the views, which
    # put no value inside '...'. Any outer assignment counts, exported or not (a spawn attempt either way).
    # Only the statements the substitution changed are read.
    global _CMD_VALS
    if len(body) > _VIEW_LEN_CAP:
        return
    if _CMD_VALS is None:
        _CMD_VALS = {} if len(cmd) > _VIEW_LEN_CAP else {
            m.group(1): next(g for g in m.groups()[1:] if g is not None) for m in _PLAIN_ASSIGN_RE.finditer(cmd)}
    starts = [] if unescaped else [body]
    # GH #816 / #820 item 1: a double-quoted body keeps the outer shell's `\$` / `\`` (shlex leaves them), which the
    # child reads as `$` / `` ` ``: `export Y=claude; bash -c "date|\$Y"`, and a body nested in a single-quoted one
    # (`bash -c 'bash -c "\$X -p x"'`). A copy with them unescaped is read too, unless the body is written
    # single-quoted only (`bash -c '\$Y -p x'` runs a command named `$Y`).
    u = re.sub(r"\\([$`])", r"\1", body) if unescaped else body
    if u != body and not ("'" + body + "'" in cmd and '"' + body + '"' not in cmd):
        starts.append(u)
    seen = None
    outer = _CMD_VALS
    if unescaped:
        outer = dict(_NESTED_VALS)
        outer.update(_CMD_VALS)
    for v in starts:
        v = _body_var_text(v, outer)
        if v is None:
            return
        # GH #816: a body's plain assignments, its values filled in, are outer values for the bodies nested in it
        # (`export Y=$X; bash -c "\$Y -p x"`), which the main reading queues after it. Only the unescaped copies read
        # them (_NESTED_VALS): the bodies as written keep develop's outer values, as a sibling body's value must not
        # come before a body's own later one (review 2: `bash -c 'Y=python3'; bash -c 'f(){ $Y -p x; }; ..; Y=claude'`).
        if not unescaped and len(_NESTED_VALS) < 1000:
            for m in _PLAIN_ASSIGN_RE.finditer(v):
                _NESTED_VALS.setdefault(m.group(1), next(g for g in m.groups()[1:] if g is not None))
        if v == body:
            continue
        if seen is None:
            seen = set(_text_statements(body))
        for st in _text_statements(v):
            if st.strip() and st not in seen and (
                    _nested_spawn(st, False) or _nested_spawn(st, True) or _nested_spawn(st, 2) or _subst_spawn(st)):
                _deny_nested_spawn()

def _body_var_text(v, outer):
    # v with its variables substituted (_scan_body_vars), or None once the shared budget is spent.
    global _BODY_VAR_WORK
    for _ in range(8):  # `Y=$X; $Y -p x`: a value that is itself a reference, up to 8 links
        _BODY_VAR_WORK += len(v)
        if _BODY_VAR_WORK > _BODY_VAR_BUDGET:
            return None  # GH #812 review 11: past one budget across all bodies, the rest keep develop's checks only
        w = _ordered_var_text(v, True, outer, True)
        if w == v or len(w) > _VIEW_LEN_CAP:  # bounded: a value holding refs (`X='$X$X'`) grows each pass
            break
        v = w
    return v

# GH #798: the views get one spawn-anchor budget of their own, the size of the main reading's, which has run.
_spawn_anchor_work, _spawn_over_budget = 0, False
if "agent_id" in d:
    # GH #816 review: every body as written first, then the unescaped copies, so a copy's expansion cannot spend the
    # shared budget before a later body as written is read.
    for _unesc in (False, True):
        for _body in _BODY_VAR_QUEUE:
            _scan_body_vars(_body, _unesc)
for _VIEW[0], _text in _views():
    try:
        # GH #798: the spawn a view's own text shows (`X=claude; $X -p x`, `bash${IFS}-c ..`), at the top level too.
        # Not brace-view (GH #661: its expansion copies a body many times, which spent the budget on legal commands);
        # a brace-built spawn is GH #731.
        _VIEW_TEXT[0] = _text
        if "agent_id" in d and _view_spawns():
            _scan_view_statements(_text)
        _start = len(windows)
        windows.extend(_view_windows(_text))
        _run_windows(_start)
        _run_words()
    except _ViewStop:
        del _WORDS[:]
        if _VIEW[0] in _VIEW_ENFORCED:
            _enforced_pass(_text)

_disarm()
sys.exit(0)
