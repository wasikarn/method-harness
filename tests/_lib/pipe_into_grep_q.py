"""pipe_into_grep_q.py FILE... -- print FILE:LINE for every pipe (`|` or `|&`) into a quiet grep.

Under `set -o pipefail`, `writer | grep -q PAT` races: grep -q exits on its first match, a writer
still writing dies of SIGPIPE (141), and pipefail turns the match into a failure.

The shell is parsed by shfmt's JSON syntax tree (mvdan.cc/sh), not by a regex or a hand-written
lexer: both missed sites or crashed in review (GH #578, #597, #598). A pipe's readers are the
commands that can read the stdin it hands its right side: the command there, every command of a
`{ }`/`( )` group, both sides of `&&`/`||`, the conditions and bodies of if/while/until/for/case, and
a `time`d command, unless that statement redirects its own stdin. A reader is a quiet grep when,
after any command/builtin/exec/env/timeout/nice/stdbuf/sudo/nohup wrapper (`env -S STRING` is split
into words), it is grep, egrep or fgrep (any path, `\\grep` too) and one of its words is -q, --quiet
or --silent (or an unambiguous abbreviation, as getopt_long allows), in a cluster such as -iEq.
GNU grep permutes, so options after operands count; option words end at `--`, and the argument of
-e/--regexp and other value-taking options is not an option. Redirections, quoted text, comments
and quoted here-document bodies are not words.

A hit whose line ends in the comment `# pipe-into-grep-q: deliberate` is exempt and printed as
`EXEMPT FILE:LINE: text` (the lint caps how many there are). Exit status: 0 clean, 1 hits printed,
2 an error (shfmt missing, a file unreadable or unparsable); hits in other files are still printed
on an error. Not caught: a grep reached through a function or alias, and early-exit readers other
than grep -q (`head`, grep -m, a command that skips stdin).
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
GREP_ARG_SHORT = set('efmABCdD')  # short options whose argument may be the next word
GREP_ARG_LONG = {'--regexp', '--file', '--max-count', '--context', '--before-context',
                 '--after-context', '--label', '--devices', '--directories', '--binary-files',
                 '--include', '--exclude', '--exclude-from', '--exclude-dir', '--group-separator'}
# wrapper -> (short option letters that take a value, long options that take a value, positionals)
WRAPPERS = {
    'command': ('', set(), 0), 'builtin': ('', set(), 0), 'exec': ('a', set(), 0),
    'env': ('uCS', {'--unset', '--chdir', '--split-string'}, 0),
    'timeout': ('ks', {'--kill-after', '--signal'}, 1),
    'nice': ('n', {'--adjustment'}, 0),
    'stdbuf': ('ioe', {'--input', '--output', '--error'}, 0),
    'nohup': ('', set(), 0),
    'sudo': ('ugpCDhrtTUg', {'--user', '--group', '--prompt', '--close-from', '--chdir', '--host',
                             '--role', '--type', '--command-timeout', '--other-user'}, 0),
}
STDIN_REDIRS = {'<', '<<<', '<<', '<<-', '<&', '<>'}
DELIBERATE = re.compile(r'#\s*pipe-into-grep-q: deliberate\s*$')


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


def has_eq(word):
    """True when a literal part of the word holds `=` (an env NAME=VALUE with an expansion)."""
    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') == 'Lit' and '=' in n.get('Value', ''):
                return True
            return any(walk(v) for k, v in n.items() if k in ('Parts',))
        if isinstance(n, list):
            return any(walk(v) for v in n)
        return False
    return walk(word)


def takes_value(w, short, long_):
    """Whether option word w consumes the next word as its value."""
    if w.startswith('--'):
        return '=' not in w and w in long_
    for n, ch in enumerate(w[1:], 1):
        if ch in short:
            return n == len(w) - 1
    return False


def is_quiet_grep(words, raw):
    """words: literal text or None per word; raw: the shfmt words (for env's NAME=$X)."""
    k = 0
    while k < len(words):
        w = words[k]
        if w is None:
            return False
        name = os.path.basename(w.replace('\\', ''))
        if name in GREPS:
            return grep_is_quiet(words[k + 1:])
        if name not in WRAPPERS:
            return False
        short, long_, positional = WRAPPERS[name]
        k += 1
        while k < len(words):
            w = words[k]
            if w is None:
                if name == 'env' and has_eq(raw[k]):
                    k += 1
                    continue
                break
            if name == 'env' and (w in ('-S', '--split-string') or w.startswith('--split-string=')
                                  or (w.startswith('-S') and len(w) > 2)):
                body = (w.split('=', 1)[1] if w.startswith('--split-string=')
                        else w[2:] if w.startswith('-S') and len(w) > 2 else None)
                if body is None:
                    if k + 1 >= len(words) or words[k + 1] is None:
                        return False
                    body, k = words[k + 1], k + 2
                else:
                    k += 1
                try:
                    split = shlex.split(body)
                except ValueError:
                    return False
                rest = split + list(words[k:])
                return is_quiet_grep(rest, [{}] * len(split) + list(raw[k:]))
            if w == '--':
                k += 1
                break
            if w.startswith('-') and len(w) > 1:
                k += 2 if takes_value(w, short, long_) else 1
                continue
            if name == 'env' and '=' in w:
                k += 1
                continue
            break
        k += positional
    return False


def grep_is_quiet(args):
    rest = iter(args)
    for w in rest:
        if w is None:
            continue
        if w == '--':
            return False
        if w.startswith('--'):
            opt = w.split('=', 1)[0]
            if '=' not in w and opt in GREP_ARG_LONG:
                next(rest, None)
            elif len(opt) >= 3 and '--quiet'.startswith(opt) or len(opt) >= 4 and '--silent'.startswith(opt):
                return True
            continue
        if w.startswith('-') and len(w) > 1:
            for n, ch in enumerate(w[1:], 1):
                if ch == 'q':
                    return True
                if ch in GREP_ARG_SHORT:
                    if n == len(w) - 1:  # `-e PAT`: the next word is the argument
                        next(rest, None)
                    break
                if not ch.isalpha():
                    break
    return False


def own_stdin(stmt):
    for r in stmt.get('Redirs') or []:
        n = (r.get('N') or {}).get('Value', '0')
        if r.get('Op') in STDIN_REDIRS and n == '0':
            return True
    return False


def readers(stmt):
    """The commands that can read the stdin a pipe hands this statement."""
    if not stmt or own_stdin(stmt):
        return []
    cmd = stmt.get('Cmd') or {}
    t = cmd.get('Type')

    def each(stmts):
        return [c for s in stmts or [] for c in readers(s)]

    if t == 'CallExpr':
        return [cmd]
    if t == 'BinaryCmd':
        if cmd.get('Op') in PIPES:
            return readers(cmd.get('X'))
        return readers(cmd.get('X')) + readers(cmd.get('Y'))
    if t in ('Block', 'Subshell'):
        return each(cmd.get('Stmts'))
    if t == 'IfClause':
        out, c = [], cmd
        while c:
            out += each(c.get('Cond')) + each(c.get('Then'))
            c = c.get('Else')
        return out
    if t == 'WhileClause':
        return each(cmd.get('Cond')) + each(cmd.get('Do'))
    if t == 'ForClause':
        return each(cmd.get('Do'))
    if t == 'CaseClause':
        return [c for item in cmd.get('Items') or [] for c in each(item.get('Stmts'))]
    if t == 'TimeClause':
        return readers(cmd.get('Stmt'))
    return []


def hits(tree):
    out = []

    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') == 'BinaryCmd' and n.get('Op') in PIPES:
                for c in readers(n.get('Y')):
                    args = c.get('Args') or []
                    if is_quiet_grep([literal(w) for w in args], args):
                        out.append(c['Pos']['Line'])
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(tree)
    return sorted(set(out))


def json_flag(shfmt):
    """`--to-json` since shfmt 3.5; older releases (Ubuntu 22.04's 3.4) only know `-tojson`."""
    for flag in ('--to-json', '-tojson'):
        if subprocess.run([shfmt, flag], input=b'', capture_output=True).returncode == 0:
            return flag
    return None


def scan(shfmt, flag, path):
    """(hit lines, exempt lines, error) for one file."""
    try:
        with open(path, 'rb') as f:
            src = f.read()
    except OSError as e:
        return [], [], f'{path}: unreadable ({e})'
    res = subprocess.run([shfmt, '-ln', 'bash', flag], input=src, capture_output=True)
    if res.returncode != 0:
        msg = res.stderr.decode('utf-8', 'replace').strip().splitlines()
        return [], [], f'{path}: shfmt cannot parse it ({msg[0] if msg else "rc " + str(res.returncode)})'
    lines = src.decode('utf-8', 'replace').split('\n')
    found, exempt = [], []
    for ln in hits(json.loads(res.stdout)):
        text = lines[ln - 1] if 0 < ln <= len(lines) else ''
        (exempt if DELIBERATE.search(text) else found).append(f'{path}:{ln}: {text.strip()}')
    return found, exempt, None


def main(paths):
    shfmt = shutil.which('shfmt')
    if not shfmt:
        print('pipe_into_grep_q: shfmt not found on PATH (macOS: brew install shfmt; Linux: '
              'apt install shfmt, pip install shfmt-py, or go install mvdan.cc/sh/v3/cmd/shfmt@latest)',
              file=sys.stderr)
        return 2
    flag = json_flag(shfmt)
    if not flag:
        print(f'pipe_into_grep_q: {shfmt} accepts neither --to-json nor -tojson', file=sys.stderr)
        return 2
    rc = 0
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
        results = list(pool.map(lambda p: scan(shfmt, flag, p), paths))
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
