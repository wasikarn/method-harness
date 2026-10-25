"""pipe_into_grep_q.py FILE... -- print FILE:LINE for every pipe (`|` or `|&`) into a quiet grep.

Under `set -o pipefail`, `writer | grep -q PAT` races: grep -q exits on its first match, a writer
still writing dies of SIGPIPE (141), and pipefail turns the match into a failure.

The shell is parsed by `shfmt --to-json` (mvdan.cc/sh), not by a regex or a hand-written lexer:
both missed sites or crashed in review (GH #578, #597, #598). From the syntax tree, a pipe's
reader is the first command on its right, or every statement of a `{ }` / `( )` group there. That
command is a quiet grep when, after any `command`/`builtin`/`exec`/`env`/`timeout`/`nice`/`stdbuf`
wrapper, it is grep, egrep or fgrep (any path, `\\grep` too) and one of its words is -q, --quiet or
--silent (in a cluster such as -iEq; GNU grep permutes, so options after operands count; option
words end at `--`). Redirections, quoted text, comments and here-document bodies are not words.

A hit on a line holding `pipe-into-grep-q: deliberate` is not reported (the lint's own race probe).
Exit status: 0 clean, 1 hits printed, 2 an error (shfmt missing, a file unreadable or unparsable).
An error is never a clean result. Not caught: a grep reached through a function or alias, and
early-exit readers other than grep -q (`head`, grep -m, a command that skips stdin).
"""
import json
import os
import shutil
import subprocess
import sys

PIPES = ('|', '|&')
GREPS = {'grep', 'egrep', 'fgrep'}
GREP_ARG_OPTS = set('efmABCdD')  # short options whose argument may be the next word
# wrapper -> (options that take a separate argument, leading positional words to skip)
WRAPPERS = {
    'command': (set(), 0), 'builtin': (set(), 0), 'exec': ({'-a'}, 0),
    'env': ({'-u', '-C', '--unset', '--chdir'}, 0),
    'timeout': ({'-k', '-s', '--kill-after', '--signal'}, 1),
    'nice': ({'-n', '--adjustment'}, 0),
    'stdbuf': ({'-i', '-o', '-e'}, 0),
}
DELIBERATE = 'pipe-into-grep-q: deliberate'


def literal(word):
    """A word's text when it holds no expansion, else None (an operand, never an option)."""
    out = ''
    for p in word.get('Parts') or []:
        t = p.get('Type')
        if t == 'Lit':
            out += p.get('Value', '')
        elif t == 'SglQuoted':
            out += p.get('Value', '')
        elif t == 'DblQuoted' and all(q.get('Type') == 'Lit' for q in p.get('Parts') or []):
            out += ''.join(q.get('Value', '') for q in p.get('Parts') or [])
        else:
            return None
    return out


def quiet_grep(call):
    words = [literal(w) for w in call.get('Args') or []]
    k = 0
    while k < len(words) and words[k] is not None:
        name = os.path.basename(words[k].replace('\\', ''))
        if name in GREPS:
            break
        if name not in WRAPPERS:
            return False
        arg_opts, positional = WRAPPERS[name]
        k += 1
        while k < len(words) and words[k] is not None and words[k].startswith('-') and words[k] != '--':
            k += 2 if words[k] in arg_opts else 1
        if k < len(words) and words[k] == '--':
            k += 1
        while k < len(words) and words[k] is not None and '=' in words[k] and name == 'env':
            k += 1  # env NAME=VALUE
        k += positional
    else:
        return False
    if k >= len(words) or words[k] is None:
        return False
    rest = iter(words[k + 1:])
    for w in rest:
        if w is None:
            continue
        if w == '--':
            return False
        if w in ('--quiet', '--silent'):
            return True
        if w.startswith('-') and not w.startswith('--'):
            for n, ch in enumerate(w[1:], 1):
                if ch == 'q':
                    return True
                if ch in GREP_ARG_OPTS:
                    if n == len(w) - 1:  # `-e PAT`: the next word is the argument
                        next(rest, None)
                    break
                if not ch.isalpha():
                    break
    return False


def readers(stmt):
    """The commands that read the stdin a pipe hands this statement."""
    cmd = (stmt or {}).get('Cmd') or {}
    t = cmd.get('Type')
    if t == 'CallExpr':
        return [cmd]
    if t == 'BinaryCmd':
        return readers(cmd.get('X'))
    if t in ('Block', 'Subshell'):
        return [c for s in cmd.get('Stmts') or [] for c in readers(s)]
    return []


def hits(tree):
    out = []

    def walk(n):
        if isinstance(n, dict):
            if n.get('Type') == 'BinaryCmd' and n.get('Op') in PIPES:
                for c in readers(n.get('Y')):
                    if quiet_grep(c):
                        out.append(c['Pos']['Line'])
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(tree)
    return sorted(set(out))


def main(paths):
    shfmt = shutil.which('shfmt')
    if not shfmt:
        print('pipe_into_grep_q: shfmt not found on PATH (macOS: brew install shfmt; Linux: '
              'apt install shfmt, pip install shfmt-py, or go install mvdan.cc/sh/v3/cmd/shfmt@latest)',
              file=sys.stderr)
        return 2
    rc = 0
    for p in paths:
        try:
            with open(p, 'rb') as f:
                src = f.read()
        except OSError as e:
            print(f'{p}: unreadable ({e})', file=sys.stderr)
            rc = 2
            continue
        res = subprocess.run([shfmt, '-ln', 'bash', '--to-json'], input=src, capture_output=True)
        if res.returncode != 0:
            msg = res.stderr.decode('utf-8', 'replace').strip().splitlines()
            print(f'{p}: shfmt cannot parse it ({msg[0] if msg else "rc " + str(res.returncode)})',
                  file=sys.stderr)
            rc = 2
            continue
        lines = src.decode('utf-8', 'replace').split('\n')
        for ln in hits(json.loads(res.stdout)):
            text = lines[ln - 1].strip() if 0 < ln <= len(lines) else ''
            if DELIBERATE in text:
                continue
            print(f'{p}:{ln}: {text}')
            rc = max(rc, 1)
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
