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
    print("[mh:gate] irrecoverable: _bracex not importable (" + str(_e) + "); a brace-hidden command is not read", file=sys.stderr)

GATE_ID = "gate:bash:irrecoverable"

try:
    d = json.load(sys.stdin)
except Exception:
    d = None

# A malformed payload that reaches this script fails closed (truncated JSON,
# tool_input:null). irrecoverable.sh short-circuits empty stdin and payloads
# with no destructive token before python runs, so those allow by design.
if not isinstance(d, dict) or not isinstance(d.get("tool_input"), dict):
    print("[mh:gate] BLOCKED: malformed PreToolUse payload — failing closed", file=sys.stderr)
    # d may be None or a non-dict here -- pass literals, never d.get(...).
    journal(GATE_ID, None, "deny", None)
    sys.exit(2)

SQ = chr(39)
_ANSI_C_QUOTE_RE = re.compile(r"\$" + SQ + r"((?:[^" + SQ + r"\\]|\\.)*)" + SQ)
# 2026-10-24 sweep: a SQL client reads SQL on stdin too (a heredoc, a here-string, a pipe), where the
# -c/-e scan in the rule loop never looks. The stripped heredoc bodies a client reads are kept here and
# checked with the stdin text further down (_sql_stdin_drop). A SQL comment separates words like a blank.
_SQL_CLIENT_RE = re.compile(r"(?<![\w.-])(?:mysql|psql|sqlite3|mariadb|mongosh|mongo|redis-cli)(?![\w.-])")
_SQL_GAP = r"(?:\s|/\*[^*]{0,200}\*/|--[^\n]{0,200}\n)+"
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

def _sql_drops(sql):
    if not _SQL_UNMODELED_RE.search(sql):
        sql = _SQL_LITERAL_RE.sub(lambda m: " " if m.group()[0] in "-/" else " s ", sql)
    return bool(_SQL_DROP_RE.search(sql))

# GH #559 review 2: set when _strip_heredocs strips a body a SQL client reads that drops, so each body is
# matched once where it is stripped (rescanning every stored body per bash -c / eval body was quadratic).
_SQL_HEREDOC_DROP = [False]

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
# A literal copy of PREFIX_WRAPPERS / FLAG_VALUE_WRAPPERS plus `builtin`: _strip_heredocs runs before those
# are defined. A wrapper missing here hides the client, as it does in the rule loop.
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
    for t in words:
        t = t.lstrip("$({`").rstrip(")}`;")
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
        return b, words
    return None, ()

def _runs_sql_client(stage):
    return _stage_cmd(stage)[0] in _SQL_CLIENTS

# GH #559 review 3: every heredoc a line opens is read, in order (cat <<A >/dev/null; psql db <<B), not
# only the first. A here-string's <<< opens none.
_HEREDOC_OPEN_RE = re.compile(r"(?<!<)<<(?!<)(-)?\s*([" + SQ + r"\"]?)([^\s" + SQ + r"\"]+)\2")
# A heredoc feeding an interpreter is executable code, not inert data: an interpreter word anywhere on the
# line BEFORE the << counts. GH #559 review 4: not only the heredoc's own pipe stage, since a heredoc on a
# compound command feeds every command in it ({ bash; } <<EOF, while read x; do bash; done <<EOF), and \b
# keeps zsh-5.9 and python3.12 interpreters. Matched once per line, at its first interpreter word.
_INTERPRETER_RE = re.compile(r"\b(bash|sh|zsh|dash|ksh|python3?|python2|perl|ruby|node|nodejs|osascript)\b")
_HEREDOC_SCAN_BUDGET = [3_000_000]  # chars a $( re-read of heredoc lines may parse; past it, a client is assumed

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
                shell[i] = shell[i + 1] or _reads_stdin_shell(self.line[st[i][0]:st[i][1]])
            self.stages[(k, "sh")] = shell
        return self.stages[(k, "sh")][j + 1]

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
_STDIN_SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
def _split_words(seg):
    try:
        return shlex.split(seg)
    except ValueError:
        return None

def _reads_stdin_shell(seg):
    w = _split_words(seg.split("<<<", 1)[0].split("<<", 1)[0])
    if not w:
        return False
    i = 0
    while i < len(w) and (re.fullmatch(r"[A-Za-z_]\w*=.*", w[i]) or w[i] in ("sudo", "env", "command", "exec", "nohup", "time")):
        i += 1
    if i >= len(w) or w[i].rsplit("/", 1)[-1] not in _STDIN_SHELLS:
        return False
    for t in w[i + 1:]:
        if t == "-s" or (t.startswith("-") and not t.startswith("--") and "s" in t[1:] and "c" not in t[1:]):
            return True  # -s: the rest are positional parameters, commands come from stdin
        if not t.startswith(("-", "+")) or (t.startswith("-") and not t.startswith("--") and "c" in t[1:]):
            return False  # a script operand, or -c
    return True

def _strip_heredocs(cmd):
    # Heredoc bodies are literal data (a quoted commit message mentioning
    # "rm -rf" must not deny) UNLESS the heredoc is stdin for an interpreter
    # (bash <<EOF / python3 <<EOF), where the body IS code and stays scannable.
    # A body a SQL client reads (psql <<EOF, cat <<EOF | mysql) is checked for a
    # drop whatever the interpreter decision (GH #559 review 3), and one that
    # drops sets _SQL_HEREDOC_DROP for the SQL check.
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        ms = list(_HEREDOC_OPEN_RE.finditer(line))
        if not ms:
            continue
        ctx, views, has_client = _HeredocLine(line), {}, bool(_SQL_CLIENT_RE.search(line))
        openers = sorted(k for k, ch in enumerate(line) if ch in "(`") if has_client else []
        interp = _INTERPRETER_RE.search(line, 0, ms[-1].start())
        for n_m, m in enumerate(ms):
            # GH #567: or a shell reading stdin downstream of it in its pipeline (cat <<EOF | bash), read
            # from the line's stages parsed once.
            code = bool(interp) and interp.start() < m.start() or ctx.piped_shell(m.start())
            feeds = has_client and _heredoc_feeds_sql_client(ctx, openers, views, m.start())
            if code and not feeds and n_m == len(ms) - 1:
                break  # the body is code: its lines stay, read (and their own heredocs stripped) as lines
            strip_tabs, delim = bool(m.group(1)), m.group(3)
            body_start, found = i, False
            while i < len(lines):
                body_line = lines[i].lstrip("\t") if strip_tabs else lines[i]
                i += 1
                if body_line == delim:
                    found = True
                    break
            if not found:
                # Unmatched closing delimiter: put the scanned lines BACK rather
                # than silently eat a real write statement that followed.
                out.extend(lines[body_start:i])
                break
            if code:
                out.extend(lines[body_start:i])
            if feeds and not _SQL_HEREDOC_DROP[0] and _sql_drops("\n".join(lines[body_start:i - 1])):
                _SQL_HEREDOC_DROP[0] = True
    return "\n".join(out)

def _normalize_ansi_c_quotes(cmd):
    # shlex does not understand ANSI-C quoting ($SQ...SQ): a spliced argv0 like
    # $SQ\x74SQ never reassembles into the decoded byte. Dispatch below compares
    # argv0 by EXACT string, so the escape must actually be RESOLVED (a
    # boundary-only re-quote still yields the literal token "gi\x74").
    # Bounded escape set: \xHH, \nnn octal, \n \t \r \\ \SQ \DQ; anything else
    # stays a literal (non-matching, safe-direction) pair.
    # A decoded SQ byte (\SQ, \047, \x27) cannot sit inside the SQ...SQ wrapper
    # returned here, so a second pass splices it into the close-escape-reopen
    # idiom -- otherwise the unbalanced quote desyncs _newlines_to_seps.
    # Decoded newlines stay INSIDE the wrapper so _newlines_to_seps (which runs
    # after this) does not read them as statement separators.
    OCTAL = "01234567"
    HEXDIGITS = "0123456789abcdefABCDEF"
    SIMPLE = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", SQ: SQ, DQ: DQ}
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
        for ch in decoded:
            if ch == SQ:
                spliced.append(SQ + "\\" + SQ + SQ)
            else:
                spliced.append(ch)
        return SQ + "".join(spliced) + SQ
    return _ANSI_C_QUOTE_RE.sub(_decode_ansi_c, cmd)

cmd = _strip_heredocs(d["tool_input"].get("command", ""))

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
}
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

def _quote_mask(c):
    # One flag per character of c: quoted ('..', $'..' or "..", its quotes included), backslash-escaped
    # or in a `#` comment. A $(..) or `..` inside ".." is unquoted again (`out="$(claude hi)"` runs claude). Linear, made once
    # per scanned text.
    mask, stack, i, n = bytearray(len(c)), [None], 0, len(c)
    while i < n:
        ch, q = c[i], stack[-1]
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
            elif ch == "$" and c[i + 1:i + 2] == "(":
                stack.append("(")
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
        elif q == "(" and ch in "()":
            stack.append(ch) if ch == "(" else stack.pop()
        elif q == "`" and ch == "`":
            stack.pop()
        i += 1
    return mask

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
    if _charge_spawn_anchor(c):
        return True
    work = 0  # shared across every anchor's scan, never reset per-anchor -- see _SPAWN_SCAN_BUDGET above
    mask = None
    for m in _SPAWN_ANCHOR_RES[overlap].finditer(c):
        stmt, work = _spawn_statement(c[m.end(1):], work)
        if stmt is None or _SPAWN_FLAG_RE.search(stmt):
            return True
        if mask is None:
            mask = _quote_mask(c)
        if mask[m.end(1) - 1]:
            continue
        a, lead = m.start(1), m.group(1)
        lead_words = _spawn_lead_words(lead)
        if lead_words is None:
            continue
        # A pipe in: `|` that is not `||`, or `|&`, up to a `(` or `{` group open; xargs hands its input
        # over as words.
        sep = re.match(r"[|;&(){\s]*", lead).group()
        piped = re.search(r"(?<!\|)\|&?[\s({]*$", c[:a] + sep) is not None or "xargs" in lead_words
        if _claude_starts_session(stmt, piped):
            return True
    return False

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

def _deny_nested_spawn():
    if _spawn_over_budget:
        print("[mh:gate] BLOCKED: subagent command is too long or too dense to check safely; write it "
              "to a file with the Write tool and run the file, or split it into smaller commands",
              file=sys.stderr)
    else:
        print("[mh:gate] BLOCKED: " + _SPAWN_DENY_REASON, file=sys.stderr)
    journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"))
    sys.exit(2)

if ("agent_id" in d) and _nested_spawn(cmd, False):
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

def _shadowed(rule, decision):
    rule = next((r for r in (rule, _VIEW[0]) if r in SHADOW_RULES), None)
    if rule is None:
        return False
    if (rule, decision) not in _SHADOW_LOGGED:
        _SHADOW_LOGGED.add((rule, decision))
        journal(GATE_ID, d.get("tool_name"), "would_" + decision, d.get("session_id"),
                rule=rule, command=cmd[:300])
    return True

def deny(reason, rule=None):
    if _VIEW[0] and rule is None:
        raise _ViewStop
    if _shadowed(rule, "deny"):
        if _VIEW[0]:
            raise _ViewStop
        return
    print("[mh:gate] BLOCKED: " + reason, file=sys.stderr)
    journal(GATE_ID, d.get("tool_name"), "deny", d.get("session_id"), rule=_VIEW[0] or rule)
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
    if (_VIEW[0] and _ASKED) or _shadowed(rule, "ask") or _ASKED:
        return
    _ASKED.append(reason)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
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
# and quote state are tracked char by char with backslash-escape parity.
DQ = chr(34)
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
# ${...} bodies are not (parameter expansion, not a command). Single-quoted
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
# never reset across the primary and fallback calls.
_DEPTH_BUDGET_BLOWN = [False]
_DEPTH_SCAN_BUDGET = 2_000_000
def _close_bracket(s, j, opener, closer, depth_work_used):
    # The "$(...)" / "${...}" closer search: from s[j] (just past the opener), count same-type
    # brackets until the matching closer, charging one budget unit per char. Returns the index just
    # past the closer, or None when there is none (end of text, or the budget ran out, which also
    # sets _DEPTH_BUDGET_BLOWN). Quotes inside the span are not tracked (GH #184).
    n, depth = len(s), 1
    while j < n and depth and depth_work_used[0] <= _DEPTH_SCAN_BUDGET:
        depth_work_used[0] += 1
        if s[j] == opener:
            depth += 1
        elif s[j] == closer:
            depth -= 1
        j += 1
    if depth and depth_work_used[0] > _DEPTH_SCAN_BUDGET:
        _DEPTH_BUDGET_BLOWN[0] = True
    return None if depth else j

def _close_psub(s, j, depth_work_used):
    # The "<(...)" / ">(...)" closer search, same contract as _close_bracket but quote-aware, unlike
    # the "$(...)"/"${...}" one: a ")" inside a quoted string in the body
    # ("<(echo \")\"; rm -rf x)") is not a real closer, and the
    # naive count-every-paren approach those siblings use closes
    # the span early on it, leaving the real dangerous tail as
    # unblanked literal text (a real regression, caught by an
    # adversarial pass; the identical gap in "$(...)" itself is
    # pre-existing and unrelated -- filed as GH #184, not fixed
    # here). Each step (one char, or an escaped pair) charges one budget unit.
    n, depth = len(s), 1
    tsq = tdq = False
    while j < n and depth and depth_work_used[0] <= _DEPTH_SCAN_BUDGET:
        depth_work_used[0] += 1
        tc = s[j]
        if tsq:
            if tc == SQ:
                tsq = False
            j += 1
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
            continue
        if tc == "(":
            depth += 1
        elif tc == ")":
            depth -= 1
        j += 1
    if depth and depth_work_used[0] > _DEPTH_SCAN_BUDGET:
        _DEPTH_BUDGET_BLOWN[0] = True
    return None if depth else j

def _substitution_at(s, i, in_dquote, bodies, depth_work_used, _depth):
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
        j = _close_bracket(s, i + 2, "(", ")", depth_work_used)
        if j is None:
            return None
        bodies.append(s[i + 2:j - 1])
        return PH, j
    if c == "$" and nxt == "{":
        j = _close_bracket(s, i + 2, "{", "}", depth_work_used)
        return None if j is None else (PH, j)
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
        # Recursively re-scanning it here (this branch only --
        # the sibling "$(...)"/"${...}" branches above share the
        # identical gap, confirmed pre-existing, filed as GH
        # #185, not fixed here) closes that while a shared
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
# backtick/$(...) bodies (never ${...}) into the shared `bodies` list.
# `depth_work_used`/`_depth`: only the <(...)/>(...) branch (GH #181)
# passes these, to recursively re-scan ITS OWN extracted body for a
# nested different-type substitution before splicing it back in verbatim
# (a backtick nested inside "<(...)" was found live/unscanned by an
# adversarial pass -- see the GH #181 comment on that branch). The
# top-level fixed-point loop below never passes them, so its own budget
# and depth are unchanged from before. Sharing one `depth_work_used`
# list across the whole recursion (never a fresh one per call) keeps the
# total work bounded by one _DEPTH_SCAN_BUDGET regardless of nesting
# depth; `_depth` caps the recursion itself, since a budget check alone
# does not stop Python's own RecursionError on ~1000 properly-closed,
# budget-cheap nested spans.
def _scan_once(s, bodies, depth_work_used=None, _depth=0):
    if depth_work_used is None:
        depth_work_used = [0]
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
            if c == SQ:
                out.append(c)
                i = _copy_squote(s, i + 1, out)
                last_escaped = False
                continue
            if c == DQ:
                in_dquote = True
                out.append(c); i += 1
                last_escaped = False
                continue
            if c == "\\" and i + 1 < n:
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
        if c in "`$<>":
            sub = _substitution_at(s, i, in_dquote, bodies, depth_work_used, _depth)
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

# shlex cost is superlinear in the longest SINGLE token (700k chars blows a 2s
# timeout), so an oversized command denies on length ALONE before shlex runs.
_CMD_LEN_CAP = 150_000
if len(cmd) > _CMD_LEN_CAP:
    deny("command too long to safely tokenize (" + str(len(cmd)) + " chars, cap " + str(_CMD_LEN_CAP) + ") - confirm with user first")

def _sql_stdin_drop(c):
    # SQL a client reads on stdin drops or truncates: a heredoc body it reads (_SQL_HEREDOC_DROP), a
    # here-string on its own stage, or the data a stage upstream of it in its pipeline emits. Text downstream
    # of the client is its output (psql -c '\d' | grep -i 'drop table'), so it is not read.
    # GH #559 review 2: only echo/printf words and a cat here-string count as emitted data; another stage's
    # words (git diff | grep -v 'DROP TABLE' | psql) are arguments, not the SQL that reaches the client.
    if _SQL_HEREDOC_DROP[0]:
        return True
    if not _SQL_CLIENT_RE.search(c) or not _SQL_DROP_RE.search(re.sub(r"[\\'\"]", "", c)):
        return False
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
        if _sql_drops(" ".join(data)):
            return True
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
                w = _split_words(g.split("<<<", 1)[1])
                if w:
                    out.append(w[0])
            up = _split_words(segs[k - 1]) if k else None
            if up and up[0] in ("echo", "printf"):
                args = up[1:]
                while up[0] == "echo" and args and re.fullmatch(r"-[neE]+", args[0]):
                    args = args[1:]
                out.append(" ".join(args).replace("\\n", "\n") if up[0] == "printf" else " ".join(args))
    return out

_SHELL_STDIN_BODIES = _shell_stdin_bodies(cmd) if any(sh in cmd for sh in _STDIN_SHELLS) else []

_SQL_BODIES_SEEN = set()  # bash -c / eval bodies already checked by _deny_sql_stdin_drop

def _deny_sql_stdin_drop(c):
    if _sql_stdin_drop(c):
        deny("destructive SQL (DROP TABLE/DATABASE/SCHEMA or TRUNCATE) sent to a SQL client on stdin — confirm with user first", rule="sql-drop")

_deny_sql_stdin_drop(cmd)

# GH #309: bash, ksh and zsh (not dash) expand a brace inside a word before anything reads it, so
# "git {,\"reset\"} --hard", "--fo{r,}{ce,}" and "r{m,} -rf" hid a verb or flag from every check below,
# which read the text literally. _bracex expands the whole command the way the shell does (lexed, so
# quotes, substitutions and comments stay what they are); the result is read as one more view
# ("brace-view", see _views), checked by every rule. A command the expansion cannot bound (nesting,
# size, a stand-in noncharacter) is a structural deny here, never skipped.
_BRACEX_TEXT = None
if _bracex and "{" in cmd:
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
                if any(_AMBIG_NARROW_AFTER.get(v, _AMBIG_ANY).search(seg, e) for v, e in first.items()):
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
    if _VIEW[0] == "brace-view":
        return  # the raw text was checked above; this deny would end the view before any rule ran (other views keep ending on it)
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
    if _DEPTH_BUDGET_BLOWN[0]:
        deny("command too long to safely tokenize (nested substitution exceeded depth-scan budget) - confirm with user first")
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
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
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
    bash takes the next word for EVERY o/O in a cluster (`-oc pipefail`, `-coo a b`); zsh, ksh and
    dash follow getopt, where an `o` followed by more letters has them as its attached value
    (`-opipefail`) and only a cluster-final `o` takes the next word. zsh's -O takes none."""
    vf = "o" if argv0 == "zsh" else "oO"

    def cluster(letters, sign):  # -> (has -c, following words consumed)
        c, extra = False, 0
        for k, ch in enumerate(letters):
            if ch == "c" and sign == "-":
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
        if t.startswith("-") and not t.startswith("--") and "c" in t:
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


# bash reads every o/O in a cluster as taking the next word; zsh, ksh and dash follow getopt; `sh`
# is bash on macOS and dash on Linux, so both readings are scanned (a wrong reading only scans one
# extra word).
_SHELL_GETOPT = {"bash": (False,), "zsh": (True,), "ksh": (True,), "dash": (True,), "sh": (False, True)}


# GH #608: an interpreter one-liner (python -c, perl/ruby -e, node -e/-p) runs a command through a string it
# hands to a process API: os.system("rm -rf x"), subprocess.run(["git", "push", "--force"]), `git reset
# --hard` in perl/ruby. When the body names such an API, each string literal, and each comma-separated run
# of literals (an argv list) joined by blanks, is scanned as a shell command line. A body with no process API
# is not read, so print("rm -rf is denied") stays allowed. API deletes (shutil.rmtree, fs.rmSync) are unseen.
_INTERP_BODY_FLAGS = {"python": ("-c",), "perl": ("-e", "-E"), "ruby": ("-e",), "node": ("-e", "--eval", "-p", "--print")}
_INTERP_NAME_RE = re.compile(r"(python)[23]?(?:\.\d+)?|(perl)(?:5[\d.]*)?|(ruby)[\d.]*|(node)(?:js)?")
_INTERP_PROC_RE = re.compile(r"\b(?:system|popen\d?|subprocess|check_output|check_call|Popen|getoutput|getstatusoutput|"
                             r"exec[lv]?[pe]{0,2}|execSync|execFileSync|execFile|spawn\w*|child_process|qx|pty)\b|%x|`")
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
            if len(run) > 1:
                out.append(" ".join(run))
            run = [text]
    if len(run) > 1:
        out.append(" ".join(run))
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
    for body in bodies:
        _scan_body(body)


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
        _deny_sql_stdin_drop(_strip_heredocs(body))
    # All three passes (GH #248). This runs inside the rule loop, so the quadratic passes could push
    # a later deny past the hook timeout; _SPAWN_ANCHOR_BUDGET bounds them and denies when over.
    if ("agent_id" in d) and (_nested_spawn(body, False) or _nested_spawn(body, True) or _nested_spawn(body, 2)):
        deny(_SPAWN_DENY_REASON + ", inside bash -c / eval either")
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
        _DEPTH_BUDGET_BLOWN[0] = True
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

def _protected_ref(name):
    # main/master/develop as the last path part, any case: "origin/main", "refs/heads/Develop".
    return name.rstrip("/").rsplit("/", 1)[-1].lower() in ("main", "master", "develop")

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
        return "git-push-force"
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
_ASSIGNED_NAMES = set(re.findall(r"(?<![\w$])([A-Za-z_]\w*)\+?=", cmd))
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

def _gh_help(scan):
    # A -h/--help that cobra reads as a flag (before "--", not a flag's value) only prints help.
    i = 0
    while i < len(scan) and scan[i] != "--":
        t = scan[i]
        if t in ("-h", "--help"):
            return True
        alone = not t.startswith("-") or t == "-" or "=" in t or t == "--version" or (not t.startswith("--") and len(t) > 2)
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
            i += 2 if t in vals else 1
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

def _find_action_chmod_world(sub):
    # GH #587: a find action running chmod (past its wrappers) with a world-writable mode applies it to
    # every file find yields, as `chmod -R` does.
    a0 = basename(sub[0]).replace(PH, "")
    i = _past_wrapper_words(a0, sub, 1) if a0 in PREFIX_WRAPPERS else 0
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
    i = _past_wrapper_words(a0, sub, 1) if a0 in PREFIX_WRAPPERS else 0
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
                                        or basename(cur[k]).replace(PH, "") in ("eval", "busybox")):
                    k += 1
                while k < len(cur) and basename(cur[k]).replace(PH, "") in PREFIX_WRAPPERS:
                    k = _past_wrapper_words(basename(cur[k]).replace(PH, ""), cur, k + 1)
                if k < len(cur) and hit(cur, k):
                    return True
                if k < len(cur) and _shell_body_runs(cur[k:], hit, depth + 1):
                    return True
    return False

def _check_window(_wi, w):
    global _cur_depth
    _cur_depth = _WDEPTH.get(_wi, 0)
    _s = 0  # an index, one slice: a flood of `!` / NAME=v words must stay linear
    while _s < len(w) and (w[_s] in SHELL_KEYWORDS or _assignment(w[_s])):
        _s += 1
    w = w[_s:]
    if not w:
        return
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
    o, env_splits, via_run_wrapper = 0, 0, False
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
            i, body, pre_rest, pre_o, split_seen = o, None, rest, o, False
            while i < len(rest):
                t = rest[i].replace(PH, "")
                long_name = t[2:].split("=", 1)[0]
                if t.startswith("--") and len(long_name) > 0 and "split-string".startswith(long_name):
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
                    words = _env_split_options(body)
                    if words is None:
                        break
                    env_splits += 1
                    if env_splits > _ENV_SPLIT_MAX:
                        deny("env -S strings that start with an option, more than %d deep - confirm with user first"
                             % _ENV_SPLIT_MAX)
                        break
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
                if _wi in _ENV_PRE570_WINDOWS:  # only a chain of them copies the tail again and again
                    _count_handover("env -S")
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

    _unwrap_shell(argv0.replace(PH, ""), rest)  # `s$(true)h -c` is still sh
    _ib = _interp_body(argv0.replace(PH, ""), rest)  # GH #608
    if _ib:
        for _c in _interp_commands(_ib):
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
                if rest[j].replace(PH, "") in ("-exec", "-execdir") and _find_action_chmod_world(sub):
                    deny("chmod 777 / a+rwx on every file find yields makes them world-writable — confirm with user first",
                         rule="chmod-world")
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
            if basename(t).replace(PH, "") in PREFIX_WRAPPERS:
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
        while _xr < len(rest) and basename(rest[_xr]).replace(PH, "") in PREFIX_WRAPPERS:
            _xr = _past_wrapper_words(basename(rest[_xr]).replace(PH, ""), rest, _xr + 1)
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
    if (_a0 in ("mkfs", "mke2fs") or _a0.startswith("mkfs.")) and any(
            not t.replace(PH, "").startswith("-") for t in rest):
        deny("mkfs formats a filesystem — irrecoverable disk-level destruction", rule="mkfs")
    if _a0 in ("chmod", "gchmod") and _chmod_world(rest):  # gchmod: GNU chmod from Homebrew (GH #587)
        deny("chmod 777 / a+rwx recursively or on / or ~ makes files world-writable — confirm with user first",
             rule="chmod-world")
    if _opaque_var(argv0, rest):
        ask("the program this runs is a variable with no visible assignment — confirm what it runs",
            rule="opaque-var-verb")
    if argv0 in ("source", ".") and rest:
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
            has_r = has_f = has_i = False
            for t in rest:
                # "$(true)-rf" IS "-rf" in bash but blanks to "PH-rf", which no
                # longer starts with "-" -- strip PH, assume the dangerous
                # (empty-substitution) resolution.
                t = t.replace(PH, "")
                if t.startswith("--"):
                    has_r = has_r or _is_flag(t, "--recursive")
                    has_f = has_f or _is_flag(t, "--force")
                    # --interactive[=always|yes] asks per file; =never/no/none and =once (-I) do not.
                    has_i = has_i or (_is_flag(t.split("=", 1)[0], "--interactive")
                                      and t.partition("=")[2] in ("", "always", "yes"))
                elif t.startswith("-") and len(t) > 1:
                    body = t[1:].lower()
                    has_r = has_r or "r" in body
                    has_f = has_f or "f" in body
                    has_i = has_i or "i" in t[1:]  # -i asks per file; -I asks once and still deletes the tree
            if has_r and has_f:
                deny("rm -rf detected — " + delete_hint(), rule="rm-rf")
            # GH #336: GNU rm takes any unambiguous prefix (`--n` is the only `--n...` option).
            if any(_is_flag(t.replace(PH, ""), "--no-preserve-root") for t in rest):
                deny("rm --no-preserve-root lifts rm's guard on / — " + delete_hint(), rule="rm-no-preserve-root")
            # 2026-10-25 (out-of-contract follow-up to the 2026-10-24 sweep): without -f, rm -r still deletes
            # the tree with no undo; -f only adds silence on write-protected files and missing paths. -i
            # prompts for every file, and the Bash tool's stdin gives no yes, so it deletes nothing unasked.
            if has_r and not has_f and not has_i:
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
                if sub == "push" and any(
                    t in ("-f", "--force") or (t.startswith("--force") and not t.startswith(("--force-with-lease", "--force-if-includes")))
                    or (t.startswith("-") and not t.startswith("--") and "f" in t)
                    or t.startswith("+")  # "+refspec" force-pushes without a -f/--force flag
                    for t in scan
                ):
                    deny("git push --force overwrites remote history — needs explicit user approval (use --force-with-lease for the safe variant)", rule="git-push-force")
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
                    deny("git reset --hard discards uncommitted work — confirm with user first", rule="git-reset-hard")
                # SHORT bundled cluster counts per-character, LONG option via
                # _is_flag's prefix match (bare containment false-positived on
                # "--find-renames" / "--format=fuller" under candidate duplication --
                # _is_flag is safe against both, see its own docstring above).
                if sub == "clean" and any(
                    _is_flag(t, "--force") or (t.startswith("-") and not t.startswith("--") and "f" in t)
                    for t in scan
                ):
                    deny("git clean -f deletes untracked files — confirm with user first", rule="git-clean-force")
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
                        deny("git restore discards working-tree changes — confirm with user first", rule="git-restore")
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
                    deny("git checkout -- / git checkout . / git checkout -f / git checkout <tree> <file> discards working-tree changes — confirm with user first", rule="git-checkout-discard")
                if sub == "switch" and any(t == "-f" or _is_flag(t, "--force", "--discard-changes") or _bundled_flag(t, ("c", "C")) for t in scan):
                    deny("git switch --force discards working-tree changes — confirm with user first", rule="git-switch-force")
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
                    if not _names or any(t.rstrip("/").rsplit("/", 1)[-1].lower() in ("main", "master", "develop") for t in _names):
                        deny("git branch -D is allowed only as a plain `git branch -D <names>` without main/master/develop — confirm with user first", rule="git-branch-force-delete")
                if sub == "stash" and args and args[0].replace(PH, "") in ("drop", "clear"):
                    deny("git stash drop/clear discards stashed changes — confirm with user first", rule="git-stash-drop")
                if sub == "commit" and any(_is_flag(t, "--amend") for t in scan):
                    deny("git commit --amend rewrites history — confirm with user first", rule="git-commit-amend")
                # `commit -n` is --no-verify (push -n is --dry-run, merge -n --no-stat, so
                # commit only). Cluster stops at a value-taking letter: -mnew is a message,
                # -Fnotes.txt a file, -tnotes a template, -uno the untracked-files mode.
                if sub == "commit" and any(_bundled_flag(t, "mFtu", "n") for t in scan):
                    deny("git commit -n is --no-verify, it bypasses safety hooks", rule="git-commit-n")
                # 2026-10-23 bypass sweep: other verbs with the same damage as a deny above.
                _nonflag = [t for t in scan if not t.startswith("-")]
                if sub == "push" and any(_is_flag(t, "--mirror", "--prune") for t in scan):
                    deny("git push --mirror/--prune overwrites or deletes remote refs, like --force — confirm with user first", rule="git-push-mirror")
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
                    deny("git worktree remove --force deletes the worktree's uncommitted changes — confirm with user first", rule="git-worktree-remove-force")
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
                    deny("git rm -f discards the uncommitted changes of the files it removes — confirm with user first", rule="git-rm-force")
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
            if gh_runs and gh_scan[0] == "pr" and [gh_scan[1:][k] for k in _gh_words(gh_scan[1:], 1)] == ["merge"]:
                ask("gh pr merge would merge a pull request into this repo — the PR-review "
                    "flow (docs/reference/branching-model.md) expects a human to do this. "
                    "Confirm this is intentional.", rule="gh-pr-merge")
            if gh_runs and gh_scan[0] == "api" and any(re.search(r"/merge(?:$|[/?#])", t) for t in gh_scan[1:]):
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
                    and re.search(r"(?<![\w./-])gh(?:\s+-\S+(?:\s+[^\s-]\S*)?)*?\s+" + re.escape(gh_scan[0])
                                  + r"(?![\w-])", cmd)):
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
_run_windows(0)

# GH #245: the overlapping spawn scan, last (see _SPAWN_ANCHOR_RES).
if ("agent_id" in d) and (_nested_spawn(cmd, True) or _nested_spawn(cmd, 2)):
    _deny_nested_spawn()
_run_words()

# GH #336: two more readings of the command, as the shell runs it, each checked by every rule above and
# owned by a rule id of its own (so it can ship shadow, GH #337): "ifs-split" reads $IFS / ${IFS} /
# ${IFS:..} as a blank and drops the empty positionals ($9, $@) used as word ends; "var-verb" reads back
# `$NAME` / `${NAME}` where the command assigns NAME a plain value (`X=rm; $X -rf x`; the last value,
# then the first). Views run only after the command passed every check; the shadow var-verb view only
# up to _VIEW_LEN_CAP: each one re-reads the whole text, and a timed-out hook allows.
# ponytail: one substitution per view, not every combination of values or of the two readings.
_IFS_RE = re.compile(r"\$(?:\{IFS(?:[:%#/^,][^}]{0,40})?\}|IFS(?![A-Za-z0-9_]))")
_EMPTY_POS_RE = re.compile(r"\$(?:[1-9@*]|\{[1-9@*]\})")
_VAR_REF_RE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
# NAME=value whose value the text alone gives: '...', "..." without $ ` \, or a bare word without them,
# ended by a blank or a separator. Read from the raw text (bash -c / eval bodies count too), not from the
# tokens: they split `RW=$R/x` into "RW=", "$", "R/x", which reads as RW assigned nothing.
_PLAIN_ASSIGN_RE = re.compile(
    r"(?<![\w$])([A-Za-z_]\w*)=(?:'([^']*)'|\"([^\"$`\\]*)\"|([^\s;&|()<>'\"$`\\]*))(?=[\s;&|()]|$)")
_VIEW_LEN_CAP = 20_000

def _views():
    out = []
    # GH #309: the command with every brace group expanded as the shell does. Shadow first (GH #337):
    # drop "brace-view" from SHADOW_RULES once /mh:gate-report shows no false positive.
    if _BRACEX_TEXT is not None:
        out.append(("brace-view", _BRACEX_TEXT))
    # The enforced ifs-split view reads as far as the parser does (_CMD_LEN_CAP); capping it lower let
    # padding past _VIEW_LEN_CAP hide `rm${IFS}-rf`. Only the shadow var-verb view keeps the lower cap.
    if "IFS" in cmd:
        v = _EMPTY_POS_RE.sub("", _IFS_RE.sub(" ", cmd))
        if v != cmd:
            out.append(("ifs-split", v))
    if len(cmd) > _VIEW_LEN_CAP:
        return out
    vals = {}
    for m in _PLAIN_ASSIGN_RE.finditer(cmd):
        vals.setdefault(m.group(1), []).append(next(g for g in m.groups()[1:] if g is not None))
    for pick in (-1, 0):
        def _sub(m, pick=pick):
            name = m.group(1) or m.group(2)
            return vals[name][pick] if name in vals else m.group(0)
        v = _VAR_REF_RE.sub(_sub, cmd) if vals else cmd
        if v != cmd and ("var-verb", v) not in out:
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

for _VIEW[0], _text in _views():
    try:
        _start = len(windows)
        windows.extend(_view_windows(_text))
        _run_windows(_start)
        _run_words()
    except _ViewStop:
        del _WORDS[:]

sys.exit(0)
