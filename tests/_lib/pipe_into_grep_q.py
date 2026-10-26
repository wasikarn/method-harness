"""pipe_into_grep_q.py FILE... -- print FILE:LINE for every pipe (`|`, `|&`, or an output process
substitution `>(...)`) into a quiet grep.

Under `set -o pipefail`, `writer | grep -q PAT` races: grep -q exits on its first match, a writer
still writing dies of SIGPIPE (141), and pipefail turns the match into a failure. A `>(grep -q ...)`
kills the command writing into it the same way, which also fails a `set -e` script with no pipe.

The shell is parsed by shfmt's JSON syntax tree (mvdan.cc/sh, `--to-json`, shfmt >= 3.5), not by a
regex or a hand-written lexer: both missed sites or crashed in review (GH #578, #597, #598). shfmt
3.4 only knows `-tojson` and encodes operators as numbers, which made every file scan clean, so the
scanner first checks itself: it must find the race in `x | grep -q y`, or it exits 2.

A pipe's readers are the commands that can read the stdin it hands its right side:
- directly: the command there, each statement of a `{ }`/`( )` group, both sides of `&&`/`||`, a
  `time`d command, and any `$(...)`/`<(...)` that expands with the pipe as stdin. Bash applies
  redirections left to right; a simple command expands its words before its redirections, a
  compound command (`for` list, `case` subject, `for ((...))`, `[[ ]]`, `(( ))`) after them;
  `>(...)` reads the command's output, not the pipe. So the words of
  `echo "$(...)" < f` read the pipe, those of `for x in $(...); do :; done < f` read f, and a
  substitution in a redirection after `< f` reads f;
- inside the conditions and bodies of if/while/until/for/case: a grep counts only when it reads
  stdin: no file operand and no -r, or a `-`, `/dev/stdin`, `/dev/fd/0` or `/proc/self/fd/0`
  operand or `-f` value
  (`while read -r f; do grep -q p "$f"; done` reads files, not the pipe). This part is a
  heuristic: a grep with a file operand after `cat` drained nothing is not flagged there.
A statement whose stdin is redirected (`<`, `<<<`, `<<`, `<&N` with a literal N other than 0) is no
reader; `<&0` and `<&"$fd"` may still be the pipe, so they are.

A `>(...)` is checked the same way, wherever it sits (either side of a pipe, or no pipe at all):
its readers are what the command writes into it, and a quiet grep there kills that command with
SIGPIPE. Over-reported: a writer whose status is discarded (`echo "$(...)"`, `<(...)`, `|| true`, a
function never called; a bare `v=$(...)` keeps the status, so under `set -e` it is a real failure),
a grep followed by a reader that drains the rest, and a `>(...)` whose fds are all redirected
elsewhere later on the same command (`cat > >(grep -q y) >/dev/null`): telling that last one apart
needs a model of fd copies, moves and `{var}` fds, and getting it wrong hides real races.

A reader is a quiet grep when, after any command/builtin/exec/env/timeout/nice/stdbuf/sudo/nohup
wrapper (with its options and, for env and sudo, NAME=VALUE words; `env -S STRING` is split and
read as `env` words), it is grep, egrep or fgrep (any path, `\\grep` too) and one of its words is
-q, --quiet or --silent. Long options, grep's and the wrappers', resolve as getopt_long does (an
unambiguous prefix or aliases, so `--qui` is --quiet, `--reg` is --regexp, `--sig` is timeout's
--signal); the value of -e/--regexp and other value-taking options is not an option; GNU grep
permutes, so options after operands count; option words end at `--`.

A hit whose line ends in the comment `# pipe-into-grep-q: deliberate` is exempt and printed as
`EXEMPT FILE:LINE: text` (the lint caps how many there are). Exit status: 0 clean, 1 hits printed,
2 an error (shfmt missing or unsupported, non-JSON output, a file unreadable or unparsable); hits in other files are
still printed on an error. Not caught: a grep reached through a function or alias, and early-exit
readers other than grep -q (`head`, grep -m, a command that skips stdin).
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

PIPES = ('|', '|&')
GREPS = {'grep', 'egrep', 'fgrep'}
# GNU grep 3.11's long options; `True` marks one that takes a value. getopt_long resolves an
# unambiguous prefix (or one whose matches are aliases, like --col for color/colour).
GREP_LONG = {
    'after-context': True, 'basic-regexp': False, 'before-context': True, 'binary': False,
    'binary-files': True, 'byte-offset': False, 'color': False, 'colour': False, 'context': True,
    'count': False, 'dereference-recursive': False, 'devices': True, 'directories': True,
    'exclude': True, 'exclude-dir': True, 'exclude-from': True, 'extended-regexp': False,
    'file': True, 'files-with-matches': False, 'files-without-match': False,
    'fixed-strings': False, 'group-separator': True, 'help': False, 'ignore-case': False,
    'include': True, 'initial-tab': False, 'invert-match': False, 'label': True,
    'line-buffered': False, 'line-number': False, 'line-regexp': False, 'max-count': True,
    'no-filename': False, 'no-group-separator': False, 'no-ignore-case': False,
    'no-messages': False, 'null': False, 'null-data': False, 'only-matching': False,
    'perl-regexp': False, 'quiet': False, 'recursive': False, 'regexp': True, 'silent': False,
    'text': False, 'version': False, 'with-filename': False, 'word-regexp': False,
}
ALIASES = {'colour': 'color'}
GREP_SHORT_VALUE = set('efmABCdD')
# wrapper -> (short option letters that take a value, its long options as GREP_LONG, positionals)
WRAPPERS = {
    'command': ('', {}, 0), 'builtin': ('', {}, 0), 'exec': ('a', {}, 0), 'nohup': ('', {}, 0),
    'env': ('uCS', {'ignore-environment': False, 'null': False, 'unset': True, 'chdir': True,
                    'split-string': True, 'block-signal': False, 'default-signal': False,
                    'ignore-signal': False, 'list-signal-handling': False, 'debug': False}, 0),
    'timeout': ('ks', {'preserve-status': False, 'foreground': False, 'kill-after': True,
                       'signal': True, 'verbose': False}, 1),
    'nice': ('n', {'adjustment': True}, 0),
    'stdbuf': ('ioe', {'input': True, 'output': True, 'error': True}, 0),
    'sudo': ('ugpCDhrtTU', {'user': True, 'group': True, 'prompt': True, 'close-from': True,
                            'chdir': True, 'host': True, 'role': True, 'type': True,
                            'command-timeout': True, 'other-user': True, 'login': False,
                            'shell': False, 'preserve-env': False, 'non-interactive': False,
                            'background': False, 'edit': False, 'list': False,
                            'validate': False, 'reset-timestamp': False,
                            'remove-timestamp': False, 'set-home': False, 'stdin': False,
                            'bell': False, 'askpass': False}, 0),
}
ASSIGNING = {'env', 'sudo'}  # wrappers that take NAME=VALUE words before the command
STDIN_REDIRS = {'<', '<<<', '<<', '<<-', '<&', '<>'}
# Keys under which shfmt nests statements; a statement's own words are everything else.
NESTED = {'Stmts', 'Cond', 'Then', 'Else', 'Do', 'Stmt', 'Body'}
# Commands that expand their words before their redirections apply.
# `[[ ]]` and `(( ))` are compound commands: bash applies their redirections first
# (`echo P | { [[ $(cat) == P ]] < f; }` reads f), so they are not here.
SIMPLE = {'CallExpr', 'DeclClause', 'LetClause'}
# Operands that name the stdin a grep inherits.
STDIN_FILES = ('-', '/dev/stdin', '/dev/fd/0', '/proc/self/fd/0')
DELIBERATE = re.compile(r'#\s*pipe-into-grep-q: deliberate\s*$')
CANARY = b'x | grep -q y\n'


def literal(word):
    """A word's text when it holds no expansion, else None (an operand, never an option)."""
    out = ''
    for p in word.get('Parts') or []:
        t = p.get('Type')
        if t in ('Lit', 'SglQuoted'):
            out += p.get('Value', '')
        elif t == 'DblQuoted' and all(q.get('Type') == 'Lit' for q in p.get('Parts') or []):
            out += ''.join(q.get('Value', '') for q in p.get('Parts') or [])
        else:
            return None
    return out


def has_eq(node):
    """True when a literal part of the word holds `=` (NAME=$VALUE)."""
    if node.get('Type') == 'Lit' and '=' in node.get('Value', ''):
        return True
    return any(has_eq(p) for p in node.get('Parts') or [])


def resolve_long(word, options):
    """getopt_long on `--name[=value]` over options: (full name or None, has `=value`)."""
    name, sep, _value = word[2:].partition('=')
    if name in options:
        return name, bool(sep)
    matches = {ALIASES.get(o, o) for o in options if o.startswith(name)} if name else set()
    return (matches.pop() if len(matches) == 1 else None), bool(sep)


def option_value(w, short, long_):
    """For a wrapper option word: (option letter or long name, whether the next word is its value)."""
    if w.startswith('--'):
        name, inline = resolve_long(w, long_)
        return name, bool(name) and long_.get(name, False) and not inline
    for n, ch in enumerate(w[1:], 1):
        if ch in short:
            return ch, n == len(w) - 1
    return None, False


def env_split(w, nxt):
    """For an env option word holding -S/--split-string: (body, words consumed), else None."""
    if w.startswith('--'):
        name, inline = resolve_long(w, WRAPPERS['env'][1])
        if name != 'split-string':
            return None
        if inline:
            return w.split('=', 1)[1], 1
        return (nxt, 2) if nxt is not None else ('', 1)
    if w.startswith('-'):
        for n, ch in enumerate(w[1:], 1):
            if ch in 'uC':  # its value is the rest of the word or the next word, not -S
                return None
            if ch == 'S':
                rest = w[n + 1:]
                if rest:
                    return rest, 1
                return (nxt, 2) if nxt is not None else ('', 1)
    return None


def grep_call(words, raw):
    """For a command's words (literal text or None) and shfmt words: the grep's argument words
    (literal or None) after any wrapper, or None when the command is not a grep."""
    k = 0
    while k < len(words):
        w = words[k]
        if w is None:
            return None
        name = os.path.basename(w.replace('\\', ''))
        if name in GREPS:
            return words[k + 1:]
        if name not in WRAPPERS:
            return None
        short, long_, positional = WRAPPERS[name]
        k += 1
        while k < len(words):
            w = words[k]
            if w is None:
                if name in ASSIGNING and has_eq(raw[k]):
                    k += 1
                    continue
                break
            if name == 'env':
                split = env_split(w, words[k + 1] if k + 1 < len(words) else None)
                if split is not None:
                    body, used = split
                    try:
                        parts = shlex.split(body)
                    except ValueError:
                        return None
                    rest = ['env'] + parts + list(words[k + used:])
                    return grep_call(rest, [{}] * (1 + len(parts)) + list(raw[k + used:]))
            if w == '--':
                k += 1
                break
            if w.startswith('-') and len(w) > 1:
                k += 2 if option_value(w, short, long_)[1] else 1
                continue
            if name in ASSIGNING and '=' in w and not w.startswith('='):
                k += 1
                continue
            break
        k += positional
    return None


def grep_args(args):
    """(quiet, reads stdin) for a grep's argument words."""
    quiet = recursive = pattern_given = patterns_from_stdin = False
    operands = []
    it = iter(args)
    for w in it:
        if w is None:
            operands.append(None)
            continue
        if w == '--':
            operands += list(it)
            break
        if w.startswith('--'):
            name, inline = resolve_long(w, GREP_LONG)
            if name in ('quiet', 'silent'):
                quiet = True
            elif name in ('recursive', 'dereference-recursive'):
                recursive = True
            elif name and GREP_LONG[name]:
                value = w.split('=', 1)[1] if inline else next(it, None)
                if name in ('regexp', 'file'):
                    pattern_given = True
                    patterns_from_stdin |= name == 'file' and value in STDIN_FILES
            continue
        if w.startswith('-') and len(w) > 1:
            for n, ch in enumerate(w[1:], 1):
                if ch == 'q':
                    quiet = True
                if ch in 'rR':
                    recursive = True
                if ch in GREP_SHORT_VALUE:
                    value = w[n + 1:] or next(it, None)
                    if ch in 'ef':
                        pattern_given = True
                        patterns_from_stdin |= ch == 'f' and value in STDIN_FILES
                    break
                if not ch.isalpha():
                    break
            continue
        operands.append(w)
    files = operands if pattern_given else operands[1:]
    if patterns_from_stdin or any(f in STDIN_FILES for f in files):
        return quiet, True
    return quiet, not files and not recursive  # -r with no file searches `.`, not stdin


def replaces_stdin(r):
    """Whether this redirection points the statement's stdin away from the pipe."""
    n = (r.get('N') or {}).get('Value', '0')
    if r.get('Op') not in STDIN_REDIRS or n != '0':
        return False
    if r.get('Op') == '<&':
        target = literal(r.get('Word') or {})
        if target is None or target == '0':
            return False  # <&0, or <&"$fd" that may be 0: still (maybe) the pipe
    return True


def substs(node):
    """The $(...) and <(...) in a command's or redirection's own words: not in the statements it
    nests (those run with their own stdin), not inside another substitution."""
    out = []

    def walk(n):
        if isinstance(n, dict):
            t = n.get('Type')
            if t in ('CmdSubst', 'ProcSubst'):
                out.append(n)
                return
            for k, v in n.items():
                # `Cond` holds statements in if/while, but an arithmetic expression in `for ((;;))`.
                if k in NESTED and not (k == 'Cond' and t not in ('IfClause', 'WhileClause')):
                    continue
                if t == 'BinaryCmd' and k in ('X', 'Y'):
                    continue
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(node)
    return out


def readers(stmt, direct=True):
    """(command, direct) pairs for the commands that can read the stdin this statement gets."""
    if not stmt:
        return []

    def each(stmts, d):
        return [r for s in stmts or [] for r in readers(s, d)]

    def subst_readers(node):
        # An output substitution `>(...)` reads what the command writes, not the pipe: hits() checks
        # every `>(...)` on its own, wherever it sits.
        return [r for sub in substs(node) if sub.get('Op') != '>('
                for r in each(sub.get('Stmts'), direct)]

    # Redirections apply left to right: a substitution in one expands with whatever stdin the
    # earlier ones left, so only those up to the first that replaces stdin can see the pipe.
    redir_out, replaced = [], False
    for r in stmt.get('Redirs') or []:
        if not replaced:
            redir_out += subst_readers(r)
        replaced = replaced or replaces_stdin(r)
    cmd = stmt.get('Cmd') or {}
    t = cmd.get('Type')
    # A simple command expands its words before its redirections apply, so substitutions in them
    # read the pipe either way; a compound command (for list, case subject) applies them first
    # (bash: `echo P | for x in $(cat); do echo $x; done < f` prints f's contents).
    simple = t in SIMPLE
    out = (subst_readers(cmd) if simple or not replaced else []) + redir_out
    if replaced:
        return out
    if t == 'CallExpr':
        return out + [(cmd, direct)]
    if t == 'BinaryCmd':
        if cmd.get('Op') in PIPES:
            return out + readers(cmd.get('X'), direct)
        return out + readers(cmd.get('X'), direct) + readers(cmd.get('Y'), direct)
    if t in ('Block', 'Subshell'):
        return out + each(cmd.get('Stmts'), direct)
    if t == 'TimeClause':
        return out + readers(cmd.get('Stmt'), direct)
    if t == 'IfClause':
        c = cmd
        while c:
            out += each(c.get('Cond'), False) + each(c.get('Then'), False)
            c = c.get('Else')
        return out
    if t == 'WhileClause':
        return out + each(cmd.get('Cond'), False) + each(cmd.get('Do'), False)
    if t == 'ForClause':
        return out + each(cmd.get('Do'), False)
    if t == 'CaseClause':
        return out + [r for item in cmd.get('Items') or [] for r in each(item.get('Stmts'), False)]
    return out


def hits(tree):
    out = []

    def check(rs):
        for c, direct in rs:
            a = c.get('Args') or []
            args = grep_call([literal(w) for w in a], a)
            if args is None:
                continue
            quiet, reads_stdin = grep_args(args)
            if quiet and (direct or reads_stdin):
                out.append(c['Pos']['Line'])

    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') == 'BinaryCmd' and n.get('Op') in PIPES:
                check(readers(n.get('Y')))
            # A `>(...)` is a pipe too: what the command writes is its stdin. A grep -q reading it
            # exits early and that command dies of SIGPIPE (bash: `tee >(grep -q 1) < big | cat`
            # gives PIPESTATUS 141 0, `seq 2000000 | tee >(grep -q 1) >/dev/null` 141 141), which
            # fails a pipefail pipeline or a `set -e` script, so it counts wherever it sits.
            if n.get('Type') == 'ProcSubst' and n.get('Op') == '>(':
                check([r for s in n.get('Stmts') or [] for r in readers(s)])
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(tree)
    return sorted(set(out))


def parse(shfmt, src):
    """(tree, error message)."""
    res = subprocess.run([shfmt, '-ln', 'bash', '--to-json'], input=src, capture_output=True)
    if res.returncode != 0:
        msg = res.stderr.decode('utf-8', 'replace').strip().splitlines()
        return None, msg[0] if msg else f'rc {res.returncode}'
    try:
        return json.loads(res.stdout), None
    except ValueError:
        return None, 'shfmt printed something that is not JSON'


def self_check(shfmt):
    """None when this shfmt's tree is one the scanner reads, else why not."""
    tree, err = parse(shfmt, CANARY)
    if err or hits(tree) != [1]:
        ver = subprocess.run([shfmt, '--version'], capture_output=True).stdout.decode().strip()
        return (f'{shfmt} ({ver or "unknown version"}) gives a syntax tree this scanner cannot read '
                f'({err or "it misses the race in `x | grep -q y`"}); shfmt >= 3.5 is needed '
                '(pip install shfmt-py, brew install shfmt, or go install mvdan.cc/sh/v3/cmd/shfmt@latest)')
    return None


def scan(shfmt, path):
    """(hit lines, exempt lines, error) for one file."""
    try:
        with open(path, 'rb') as f:
            src = f.read()
    except OSError as e:
        return [], [], f'{path}: unreadable ({e})'
    tree, err = parse(shfmt, src)
    if err:
        return [], [], f'{path}: shfmt cannot parse it ({err})'
    lines = src.decode('utf-8', 'replace').split('\n')
    found, exempt = [], []
    for ln in hits(tree):
        text = lines[ln - 1] if 0 < ln <= len(lines) else ''
        (exempt if DELIBERATE.search(text) else found).append(f'{path}:{ln}: {text.strip()}')
    return found, exempt, None


def main(paths):
    shfmt = shutil.which('shfmt')
    if not shfmt:
        print('pipe_into_grep_q: shfmt not found on PATH (shfmt >= 3.5: brew install shfmt, '
              'pip install shfmt-py, or go install mvdan.cc/sh/v3/cmd/shfmt@latest)', file=sys.stderr)
        return 2
    why = self_check(shfmt)
    if why:
        print(f'pipe_into_grep_q: {why}', file=sys.stderr)
        return 2
    rc = 0
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
        results = list(pool.map(lambda p: scan(shfmt, p), paths))
    for found, exempt, err in results:
        for line in exempt:
            print(f'EXEMPT {line}')
        for line in found:
            print(line)
            rc = max(rc, 1)
        if err:
            print(err, file=sys.stderr)
            rc = 2
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
