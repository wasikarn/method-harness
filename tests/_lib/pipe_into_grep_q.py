"""pipe_into_grep_q.py FILE... -- print FILE:LINE for every pipe (`|` or `|&`) into a quiet grep.

Under `set -o pipefail`, `writer | grep -q PAT` races: grep -q exits on its first match, a writer
still writing dies of SIGPIPE (141), and pipefail turns the match into a failure. The scanner is a
small shell lexer, not a line regex, because regexes missed sites twice (GH #578, #597):
- `\\`-newline continuations and a newline after `|` are joined;
- quoted text is opaque (a `-q` or `|` inside a pattern is not code), but `$(...)` inside double
  quotes is code, so `"$(cmd | grep -q x)"` is still seen;
- comments, `$((...))` arithmetic and here-document bodies (data) are skipped;
- the grep may follow assignments and `command`, `builtin`, `exec` or `env`, may be written `\\grep`,
  `/usr/bin/grep`, `egrep` or `fgrep`, and is quiet when one of its options is -q, --quiet or
  --silent (in a cluster such as -iEq; option words end at `--`).
Exit status: 1 when anything is printed, else 0. Not caught: a grep reached through a function or
alias, and early-exit readers other than grep -q (`head`, grep -m, a command that skips stdin).
"""
import os
import re
import sys

ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
PREFIX = {'command', 'builtin', 'exec', 'env'}
GREPS = {'grep', 'egrep', 'fgrep'}
ARG_OPTS = set('efmABCdD')  # short options whose argument may follow in the same word


class Lexer:
    """Turns shell text into ('w', word, line) / ('op', op, line) tokens."""

    def __init__(self, text):
        self.s = text
        self.i = 0
        self.line = 1
        self.toks = []
        self.heredocs = []  # (delimiter, strip_tabs) waiting for the next newline

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < len(self.s) else ''

    def adv(self, n=1):
        for _ in range(n):
            if self.i < len(self.s) and self.s[self.i] == '\n':
                self.line += 1
            self.i += 1

    def op(self, o):
        self.toks.append(('op', o, self.line))

    def skip_heredocs(self):
        for delim, strip in self.heredocs:
            while self.i < len(self.s):
                end = self.s.find('\n', self.i)
                end = len(self.s) if end < 0 else end
                body = self.s[self.i:end]
                self.adv(end - self.i + 1)
                if (body.lstrip('\t') if strip else body) == delim:
                    break
        self.heredocs = []

    def skip_squote(self):
        self.adv()
        while self.i < len(self.s) and self.peek() != "'":
            self.adv()
        self.adv()

    def skip_ansi(self):  # $'...'
        self.adv(2)
        while self.i < len(self.s) and self.peek() != "'":
            self.adv(2 if self.peek() == '\\' else 1)
        self.adv()

    def skip_arith(self):  # $(( ... ))
        self.adv(3)
        depth = 0
        while self.i < len(self.s):
            if self.peek() == '(':
                depth += 1
            elif self.peek() == ')':
                if depth == 0 and self.peek(1) == ')':
                    self.adv(2)
                    return
                depth -= 1
            self.adv()

    def dquote(self):
        """Skip a double-quoted string; lex any $(...) inside it as code."""
        self.adv()
        while self.i < len(self.s):
            c = self.peek()
            if c == '\\':
                self.adv(2)
            elif c == '"':
                self.adv()
                return
            elif c == '$' and self.peek(1) == '(' and self.peek(2) == '(':
                self.skip_arith()
            elif c == '$' and self.peek(1) == '(':
                self.adv(2)
                self.op('(')
                self.code(close=')')
                self.op(')')
            else:
                self.adv()

    def heredoc_start(self):
        """At `<<` (not `<<<`): queue the delimiter; return the redirection as consumed."""
        self.adv(2)
        strip = self.peek() == '-'
        if strip:
            self.adv()
        while self.peek() in ' \t':
            self.adv()
        delim = ''
        while self.i < len(self.s) and self.peek() not in ' \t\n;&|<>()':
            c = self.peek()
            if c in '\'"':
                q = c
                self.adv()
                while self.i < len(self.s) and self.peek() != q:
                    delim += self.peek()
                    self.adv()
                self.adv()
            else:
                if c == '\\':
                    self.adv()
                    c = self.peek()
                delim += c
                self.adv()
        if delim:
            self.heredocs.append((delim, strip))

    def code(self, close=None):
        word = None
        depth = 0  # plain ( ) nesting inside this frame

        def flush():
            nonlocal word
            if word is not None:
                self.toks.append(('w', word, wline))
                word = None

        wline = self.line
        while self.i < len(self.s):
            c = self.peek()
            if c == '\\' and self.peek(1) == '\n':
                self.adv(2)
                continue
            if c == '\n':
                flush()
                self.op('nl')
                self.adv()
                if self.heredocs:
                    self.skip_heredocs()
                continue
            if c in ' \t':
                flush()
                self.adv()
                continue
            if c == '#' and word is None:
                while self.i < len(self.s) and self.peek() != '\n':
                    self.adv()
                continue
            if c == ')' and close == ')' and depth == 0:
                flush()
                self.adv()
                return
            if word is None:
                wline = self.line
            if c == '\\':
                self.adv()
                word = (word or '') + self.peek()
                self.adv()
            elif c == "'":
                word = (word or '') + 'Q'
                self.skip_squote()
            elif c == '$' and self.peek(1) == "'":
                word = (word or '') + 'Q'
                self.skip_ansi()
            elif c == '"':
                word = (word or '') + 'Q'
                self.dquote()
            elif c == '$' and self.peek(1) == '(' and self.peek(2) == '(':
                word = (word or '') + 'Q'
                self.skip_arith()
            elif c == '$' and self.peek(1) == '(':
                word = (word or '') + 'Q'
                flush()
                self.adv(2)
                self.op('(')
                self.code(close=')')
                self.op(')')
            elif c == '`':
                flush()
                self.adv()
                self.op('(')
                start = self.i
                while self.i < len(self.s) and self.peek() != '`':
                    self.adv(2 if self.peek() == '\\' else 1)
                sub = Lexer(self.s[start:self.i])
                sub.line = self.line
                sub.code()
                self.toks.extend(sub.toks)
                self.adv()
                self.op(')')
            elif c == '<' and self.peek(1) == '<' and self.peek(2) != '<':
                flush()
                self.heredoc_start()
            elif c in '|&;()<>':
                flush()
                two = c + self.peek(1)
                if two in ('||', '&&', ';;', '|&', '>>', '<<', '&>', '>&', '<&'):
                    self.op(two)
                    self.adv(2)
                else:
                    if c == '(':
                        depth += 1
                    elif c == ')':
                        depth -= 1
                    self.op(c)
                    self.adv()
            else:
                word = (word or '') + c
                self.adv()
        flush()


def quiet_grep(words):
    k = 0
    while k < len(words) and (ASSIGN.match(words[k]) or words[k] in PREFIX
                              or (words[k] == '-i' and k and words[k - 1] == 'env')):
        k += 1
    if k >= len(words) or os.path.basename(words[k]) not in GREPS:
        return False
    rest = iter(words[k + 1:])
    for w in rest:
        if w == '--':
            return False
        if w in ('--quiet', '--silent'):
            return True
        if w.startswith('-') and not w.startswith('--'):
            for n, ch in enumerate(w[1:], 1):
                if ch == 'q':
                    return True
                if ch in ARG_OPTS:
                    if n == len(w) - 1:  # `-e PAT`: the next word is the argument, not an option
                        next(rest, None)
                    break
                if not ch.isalpha():
                    break
    return False


def hits(text):
    lx = Lexer(text)
    lx.code()
    toks = lx.toks
    out = []
    for n, (kind, val, _) in enumerate(toks):
        if kind != 'op' or val not in ('|', '|&'):
            continue
        j = n + 1
        while j < len(toks) and toks[j][:2] == ('op', 'nl'):
            j += 1
        words, line = [], None
        while j < len(toks) and toks[j][0] == 'w':
            line = line or toks[j][2]
            words.append(toks[j][1])
            j += 1
        if words and quiet_grep(words):
            out.append(line)
    return out


def main(paths):
    found = False
    for p in paths:
        try:
            text = open(p, encoding='utf-8', errors='replace').read()
        except OSError as e:
            print(f'{p}: unreadable ({e})', file=sys.stderr)
            found = True
            continue
        lines = text.split('\n')
        for ln in hits(text):
            found = True
            print(f'{p}:{ln}: {lines[ln - 1].strip()}')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
