#!/usr/bin/env python3
"""citation_exists.py -- report-only: do the path:line and commit-SHA citations in a text exist?

check-verdict.py and check-citations.py check citation SHAPE only (CITATION_RE in
verdict_json.py). This script resolves each cite against one or more repo roots and gives
it one of three labels:

  resolved              the file exists under the roots (one real file) and the line is in
                        range; or a SHA `git cat-file -e` finds in some root; or the path is
                        listed in --diff-paths (a file the reviewed diff deleted).
  missing               the path's first directory exists under a root but the file does
                        not, or the line is past the file's last line.
  ambiguous-or-outside  a bare basename matching zero or several files; a first directory
                        under no root; a `..` segment, an absolute path outside every root,
                        or a symlink whose target leaves its root; a SHA found in no root.

Input that is one JSON object or array (check-verdict.py's output) is read as its string values
(keys are skipped), so a cite after an escaped or double-escaped newline is still found; `(line N)`
is then the 1-based index of the string value, in document order, even when a string holds
newlines. Any other input is read as it is, `(line N)` being its own line.
A line number of more than 9 digits (leading zeros do not count) is a cite past the end of any file:
`missing`.
A backticked command is never run, but a path:line inside it is still extracted and checked.
A word of 7 to 40 hex characters with a digit and a letter (a CSS colour, a hash) counts as a
SHA cite and lands in ambiguous-or-outside. `missing` can also mean a cite into another repo
whose first directory matches one under a root, so it is not proof of fabrication.
Never writes anything. Exit 0 whenever it ran,
2 on a usage error (unreadable input, no --root).

--diff-paths FILE lists one path per line, as `git diff --name-only` prints them (use
--diff-filter=D to list only deleted files). A listed path is read as present only when no file
is found on disk, so the line check still runs for a file that exists. A raw unified diff is
not parsed. A --root that is not a directory is skipped with a warning on stderr; the run
exits 2 only when no usable root is left.

Usage: citation_exists.py --root PATH [--root PATH ...] [--diff-paths FILE] [--json] [FILE]
       citation_exists.py --selftest
Tests: tests/scripts/test-citation-exists.sh
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys

RESOLVED, MISSING, OUTSIDE = "resolved", "missing", "ambiguous-or-outside"
LABELS = (RESOLVED, MISSING, OUTSIDE)
# The path:line idea of verdict_json.CITATION_RE (a letter, and a "." or "/"), with an
# optional -line range and a tighter path character set so "(src/a.py:3" drops the "(".
# Linear: one greedy run of path characters, then ":N"; the letter and "./" rules run in extract().
# A backslash before the run (a Windows path) rejects it, so no basename is cut out of it.
PATH_RE = re.compile(r"(?<![\w./@+\\-])([\w./@+-]+):(\d+)(?:-(\d+))?")
HAS_LETTER = re.compile(r"[A-Za-z]")
SHA_RE = re.compile(r"(?<![\w./@+-])(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![\w@+-])")
SKIP_DIRS = {".git", "node_modules"}
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


BEYOND_ANY_FILE = 10 ** 9  # a line number of more than 9 digits is past the end of any real file
# A checker that double-escapes writes a literal backslash and n/t/r after a cite's line number; PATH_RE would
# take that backslash for a Windows path and drop the next cite. Only right after a `:line` or `:line-line` number,
# so a Windows folder that ends in a digit (`C:\dir1\new.py`) stays whole.
# Also a run of escapes (`\r\n`) and a closing quote, backtick or bracket before them (GH #982).
LITERAL_ESCAPE = re.compile(r"(:\d+(?:-\d+)?[)\]}\"'`]*)(?:\\[nrt])+")


def _line_number(digits):
    # int() of a very long digit run raises ValueError (Python's 4300-digit limit); such a cite is simply missing.
    # Leading zeros are not digits of the value.
    return int(digits) if len(digits.lstrip("0")) <= 9 else BEYOND_ANY_FILE


def _lines(text):
    """The units a cite is numbered by: the string values of one JSON object or array, else the text's lines.

    check-verdict.py's output is JSON, where a newline or tab inside a string is written as a backslash
    escape; left raw, that backslash would sit in front of the next cite and hide it (PATH_RE rejects a
    path after a backslash). Keys and numbers are not scanned or numbered; an integer is dropped before
    int() runs, so one of thousands of digits cannot make the parse fail and fall back to the raw text."""
    try:
        doc = json.loads(text, parse_int=lambda _: None)
    except (ValueError, RecursionError):
        return text.splitlines()
    if not isinstance(doc, (dict, list)):
        return text.splitlines()
    out, todo = [], [doc]
    while todo:
        v = todo.pop()
        if isinstance(v, str):
            out.append(LITERAL_ESCAPE.sub(r"\1 ", v))
        elif isinstance(v, dict):
            todo.extend(reversed(list(v.values())))
        elif isinstance(v, list):
            todo.extend(reversed(v))
    return out


def extract(text):
    """Yield (line_no, kind, citation, path, last_line) for every cite in text."""
    for n, line in enumerate(_lines(text), 1):
        starts, ends = [], []  # the path cites' spans, in order and disjoint, so a SHA lookup can bisect
        for m in PATH_RE.finditer(line):
            if not HAS_LETTER.search(m.group(1)) or not ("." in m.group(1) or "/" in m.group(1)):
                continue
            starts.append(m.start())
            ends.append(m.end())
            yield n, "path", m.group(0), m.group(1), (_line_number(m.group(2)), _line_number(m.group(3) or m.group(2)))
        for m in SHA_RE.finditer(line):
            i = bisect.bisect_right(starts, m.start()) - 1
            if i < 0 or m.start() >= ends[i]:
                yield n, "sha", m.group(0), m.group(0), None


def _inside(real, root):
    return real == root or real.startswith(root + os.sep)


def _line_count(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    return data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)


class Resolver:
    def __init__(self, roots, diff_paths):
        self.roots = [os.path.realpath(r) for r in roots]
        self.diff = diff_paths
        self._names = None
        self._shas = {}

    def _basename_index(self):
        if self._names is None:
            self._names = {}
            for root in self.roots:
                for d, dirs, files in os.walk(root):
                    dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
                    for f in files:
                        self._names.setdefault(f, set()).add(os.path.join(d, f))
        return self._names

    def _real_files(self, candidates):
        """Real paths of candidates that are files and stay inside their root, or None
        when one escapes its root through a symlink."""
        out = set()
        for root, p in candidates:
            if not os.path.isfile(p):
                continue
            real = os.path.realpath(p)
            if not _inside(real, root):
                return None
            out.add(real)
        return out

    def _check_lines(self, real, span):
        first, last = span
        count = _line_count(real)
        if count is None:
            return OUTSIDE
        return RESOLVED if 1 <= first <= last <= count else MISSING

    def resolve_path(self, cited, span):
        norm = cited[2:] if cited.startswith("./") else cited
        if ".." in norm.split("/"):
            return OUTSIDE
        if os.path.isabs(norm):
            real = os.path.realpath(norm)
            hit = [r for r in self.roots if _inside(real, r)]
            if not hit or not os.path.isfile(real):
                return OUTSIDE if not hit else MISSING
            return self._check_lines(real, span)
        if "/" not in norm.strip("/"):
            found = self._real_files((r, p) for r in self.roots
                                     for p in self._basename_index().get(norm, ())
                                     if p.startswith(r + os.sep))
            if found is None or len(found) > 1:
                return OUTSIDE
            if found:
                return self._check_lines(found.pop(), span)
            return RESOLVED if norm in self.diff else OUTSIDE
        found = self._real_files((r, os.path.join(r, norm)) for r in self.roots)
        if found is None or len(found) > 1:
            return OUTSIDE
        if found:
            return self._check_lines(found.pop(), span)
        if norm in self.diff:  # deleted by the reviewed diff: gone from the tree, still a real cite
            return RESOLVED
        first = norm.split("/", 1)[0]
        if any(os.path.isdir(os.path.join(r, first)) for r in self.roots):
            return MISSING
        return OUTSIDE

    def resolve_sha(self, sha):
        if sha not in self._shas:
            self._shas[sha] = OUTSIDE
            for r in self.roots:
                p = subprocess.run(["git", "-C", r, "cat-file", "-e", sha + "^{commit}"],
                                   env=GIT_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if p.returncode == 0:
                    self._shas[sha] = RESOLVED
                    break
        return self._shas[sha]


def check(text, roots, diff_paths=()):
    res = Resolver(roots, set(diff_paths))
    items = []
    for n, kind, cite, target, span in extract(text):
        label = res.resolve_path(target, span) if kind == "path" else res.resolve_sha(target)
        items.append({"line": n, "kind": kind, "citation": cite, "label": label})
    counts = {k: sum(1 for i in items if i["label"] == k) for k in LABELS}
    return {"resolved": counts["resolved"], "total": len(items), "counts": counts, "items": items}


def render(report):
    out = ["citations exist: %d of %d resolved" % (report["resolved"], report["total"])]
    out += ["  %s: %d" % (k, report["counts"][k]) for k in LABELS]
    out += ["%s  %s  (line %d)" % (i["label"], i["citation"], i["line"])
            for i in report["items"] if i["label"] != RESOLVED]
    return "\n".join(out)


def _selftest():
    got = [(k, c) for _, k, c, _, _ in extract("a src/x.py:3 and (docs/y.md:1-4) 2.5:1 1.1.591 cafe123 abcdef0123")]
    assert got == [("path", "src/x.py:3"), ("path", "docs/y.md:1-4"), ("sha", "cafe123"), ("sha", "abcdef0123")], got
    assert [c for _, _, c, _, _ in extract("only digits 1234567, only letters deadbeef")] == []
    assert check("", ["."])["total"] == 0
    print("citation_exists.py selftest ok")


def main(argv):
    ap = argparse.ArgumentParser(description="Report which path:line and SHA citations exist.")
    ap.add_argument("file", nargs="?")
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--diff-paths")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        _selftest()
        return 0
    roots = [r for r in a.root if os.path.isdir(r)]
    for r in a.root:
        if r not in roots:
            print("citation_exists: skipping --root %s (not a directory)" % r, file=sys.stderr)
    if not roots:
        print("citation_exists: give at least one --root that is an existing directory", file=sys.stderr)
        return 2
    try:
        text = open(a.file, encoding="utf-8", errors="replace").read() if a.file else sys.stdin.read()
        diff = []
        if a.diff_paths:
            with open(a.diff_paths, encoding="utf-8") as f:
                diff = [ln.strip().removeprefix("./") for ln in f if ln.strip()]
    except (OSError, UnicodeDecodeError) as e:
        print("citation_exists: cannot read input: %s" % e, file=sys.stderr)
        return 2
    report = check(text, roots, diff)
    print(json.dumps(report, indent=2) if a.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
