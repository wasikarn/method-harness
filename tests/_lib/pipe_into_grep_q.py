"""pipe_into_grep_q.py FILE... -- print FILE:LINE for every pipe (`|` or `|&`) into a quiet grep.

Under `set -o pipefail`, `writer | grep -q PAT` races: grep -q exits on its first match, a writer
still writing dies of SIGPIPE (141), and pipefail turns the match into a failure.

The shell is parsed by shfmt's JSON syntax tree (mvdan.cc/sh, `--to-json`, shfmt >= 3.5), not by a
regex or a hand-written lexer: both missed sites or crashed in review (GH #578, #597, #598). shfmt
3.4 only knows `-tojson` and encodes operators as numbers, which made every file scan clean, so the
scanner first checks itself: it must find the race in `x | grep -q y`, or it exits 2.

A pipe's readers are the commands that can read the stdin it hands its right side:
- directly: the command there, each statement of a `{ }`/`( )` group, both sides of `&&`/`||`, a
  `time`d command, and any `$(...)`/`<(...)` inside such a command's words or assignments;
- inside the conditions and bodies of if/while/until/for/case: a grep counts only when it has no
  file operand (`while read -r f; do grep -q p "$f"; done` reads files, not the pipe). This part is
  a heuristic: a grep with a file operand after `cat` drained nothing is not flagged there.
A statement whose stdin is redirected (`<`, `<<<`, `<<`, `<&N` with N other than 0) is no reader.

A reader is a quiet grep when, after any command/builtin/exec/env/timeout/nice/stdbuf/sudo/nohup
wrapper (with its options and, for env and sudo, NAME=VALUE words; `env -S STRING` is split and
read as `env` words), it is grep, egrep or fgrep (any path, `\\grep` too) and one of its words is
-q, --quiet or --silent. Long options resolve as getopt_long does (an unambiguous prefix, so `--qui`
is --quiet and `--reg` is --regexp); the value of -e/--regexp and other value-taking options is not
an option; GNU grep permutes, so options after operands count; option words end at `--`.

A hit whose line ends in the comment `# pipe-into-grep-q: deliberate` is exempt and printed as
`EXEMPT FILE:LINE: text` (the lint caps how many there are). Exit status: 0 clean, 1 hits printed,
2 an error (shfmt missing or unsupported, a file unreadable or unparsable); hits in other files are
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
# GNU grep 3.11's long options (getopt_long resolves an unambiguous prefix to one of these).
GREP_LONG = [
    'after-context', 'basic-regexp', 'before-context', 'binary', 'binary-files', 'byte-offset',
    'color', 'colour', 'context', 'count', 'dereference-recursive', 'devices', 'directories',
    'exclude', 'exclude-dir', 'exclude-from', 'extended-regexp', 'file', 'files-with-matches',
    'files-without-match', 'fixed-strings', 'group-separator', 'help', 'ignore-case', 'include',
    'initial-tab', 'invert-match', 'label', 'line-buffered', 'line-number', 'line-regexp',
    'max-count', 'no-filename', 'no-group-separator', 'no-ignore-case', 'no-messages', 'null',
    'null-data', 'only-matching', 'perl-regexp', 'quiet', 'recursive', 'regexp', 'silent', 'text',
    'version', 'with-filename', 'word-regexp',
]
GREP_LONG_VALUE = {'after-context', 'before-context', 'binary-files', 'context', 'devices',
                   'directories', 'exclude', 'exclude-dir', 'exclude-from', 'file',
                   'group-separator', 'include', 'label', 'max-count', 'regexp'}
GREP_SHORT_VALUE = set('efmABCdD')
# wrapper -> (short option letters that take a value, long options that take a value, positionals)
WRAPPERS = {
    'command': ('', set(), 0), 'builtin': ('', set(), 0), 'exec': ('a', set(), 0),
    'env': ('uC', {'--unset', '--chdir'}, 0),
    'timeout': ('ks', {'--kill-after', '--signal'}, 1),
    'nice': ('n', {'--adjustment'}, 0),
    'stdbuf': ('ioe', {'--input', '--output', '--error'}, 0),
    'nohup': ('', set(), 0),
    'sudo': ('ugpCDhrtTU', {'--user', '--group', '--prompt', '--close-from', '--chdir', '--host',
                            '--role', '--type', '--command-timeout', '--other-user'}, 0),
}
ASSIGNING = {'env', 'sudo'}  # wrappers that take NAME=VALUE words before the command
STDIN_REDIRS = {'<', '<<<', '<<', '<<-', '<&', '<>'}
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


def takes_value(w, short, long_):
    """Whether wrapper option word w consumes the next word as its value."""
    if w.startswith('--'):
        return '=' not in w and w in long_
    for n, ch in enumerate(w[1:], 1):
        if ch in short:
            return n == len(w) - 1
    return False


def env_split(w, nxt):
    """For an env option word holding -S: (split body, words consumed), else None."""
    if w.startswith('--split-string='):
        return w.split('=', 1)[1], 1
    if w == '--split-string':
        return (nxt, 2) if nxt is not None else ('', 1)
    if w.startswith('-') and not w.startswith('--'):
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
                k += 2 if takes_value(w, short, long_) else 1
                continue
            if name in ASSIGNING and '=' in w and not w.startswith('='):
                k += 1
                continue
            break
        k += positional
    return None


def resolve_long(opt):
    """getopt_long: an exact name, or the one long option an abbreviation names, else None."""
    name = opt[2:]
    if name in GREP_LONG:
        return name
    matches = [o for o in GREP_LONG if o.startswith(name)]
    return matches[0] if len(matches) == 1 else None


def grep_args(args):
    """(quiet, reads stdin) for a grep's argument words."""
    quiet = False
    pattern_given = False
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
            opt, _, value = w.partition('=')
            name = resolve_long(opt)
            if name in ('quiet', 'silent'):
                quiet = True
            elif name in GREP_LONG_VALUE:
                if name in ('regexp', 'file'):
                    pattern_given = True
                if not _:
                    next(it, None)
            continue
        if w.startswith('-') and len(w) > 1:
            for n, ch in enumerate(w[1:], 1):
                if ch == 'q':
                    quiet = True
                if ch in GREP_SHORT_VALUE:
                    if ch in 'ef':
                        pattern_given = True
                    if n == len(w) - 1:
                        next(it, None)
                    break
                if not ch.isalpha():
                    break
            continue
        operands.append(w)
    files = operands if pattern_given else operands[1:]
    reads_stdin = not files or '-' in files
    return quiet, reads_stdin


def own_stdin(stmt):
    for r in stmt.get('Redirs') or []:
        n = (r.get('N') or {}).get('Value', '0')
        if r.get('Op') not in STDIN_REDIRS or n != '0':
            continue
        if r.get('Op') == '<&' and literal(r.get('Word') or {}) == '0':
            continue  # <&0 duplicates the stdin it already has: still the pipe
        return True
    return False


def substs(node):
    """The $(...) and <(...) nodes inside a command, not inside nested ones."""
    out = []

    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') in ('CmdSubst', 'ProcSubst'):
                out.append(n)
                return
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(node)
    return out


def readers(stmt, direct=True):
    """(command, direct) pairs for the commands that can read the stdin this statement gets."""
    if not stmt or own_stdin(stmt):
        return []
    cmd = stmt.get('Cmd') or {}
    t = cmd.get('Type')

    def each(stmts, d):
        return [r for s in stmts or [] for r in readers(s, d)]

    if t in ('CallExpr', 'DeclClause', 'TestClause', 'ArithmCmd', 'LetClause'):
        out = [(cmd, direct)] if t == 'CallExpr' else []
        for sub in substs(cmd):
            out += each(sub.get('Stmts'), direct)
        return out
    if t == 'BinaryCmd':
        if cmd.get('Op') in PIPES:
            return readers(cmd.get('X'), direct)
        return readers(cmd.get('X'), direct) + readers(cmd.get('Y'), direct)
    if t in ('Block', 'Subshell'):
        return each(cmd.get('Stmts'), direct)
    if t == 'TimeClause':
        return readers(cmd.get('Stmt'), direct)
    if t == 'IfClause':
        out, c = [], cmd
        while c:
            out += each(c.get('Cond'), False) + each(c.get('Then'), False)
            c = c.get('Else')
        return out
    if t == 'WhileClause':
        return each(cmd.get('Cond'), False) + each(cmd.get('Do'), False)
    if t == 'ForClause':
        return each(cmd.get('Do'), False)
    if t == 'CaseClause':
        return [r for item in cmd.get('Items') or [] for r in each(item.get('Stmts'), False)]
    return []


def hits(tree):
    out = []

    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') == 'BinaryCmd' and n.get('Op') in PIPES:
                for c, direct in readers(n.get('Y')):
                    a = c.get('Args') or []
                    args = grep_call([literal(w) for w in a], a)
                    if args is None:
                        continue
                    quiet, reads_stdin = grep_args(args)
                    if quiet and (direct or reads_stdin):
                        out.append(c['Pos']['Line'])
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
    return json.loads(res.stdout), None


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
