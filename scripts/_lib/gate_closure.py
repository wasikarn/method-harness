#!/usr/bin/env python3
"""gate_closure.py (GH #891): the content hash of the files one replay-supported gate runs.

Usage: gate_closure.py [--files] (--dir GATES_DIR | --rev REV) GATE
  --dir  read hooks/gates files from a folder (gate-differential.py's NEW snapshot)
  --rev  read hooks/gates/ at a git rev, in the cwd's repo, from its top (merge-pr.sh's merge tree)
  --files  print the member file names, one per line, instead of the hash
GATE: irrecoverable | subagent-git-guard | secret-scan. Exit 2 on a usage error, 1 when git fails.

Members, all directly in hooks/gates: the gate's own .sh and .py, _run.py, and each shared _*.py, _*.sh or
*.awk file the gate uses. A shared file is used when its name without the extension is a whole word in the
gate's .sh or .py, or in a member already counted (_run.py included) (`from _journal import`, `brace-route.awk`).
A name that only a comment mentions counts too; a name built at run time would be missed.
The hash is sha256 over "<name>\\0<sha256 of the bytes>\\n" per member, sorted by name, so the same
bytes give the same hash from a folder or from git. Other gates' files are never members, so a develop
merge that touches only another gate keeps a replay record valid.
"""
import hashlib, os, re, subprocess, sys

GATES = ("irrecoverable", "subagent-git-guard", "secret-scan")


def _shared(name):
    # Real gate files only: an ignored backup (`_journal.py~`, `_run.py.orig`) in a folder would join the
    # folder's closure but never a rev's, and the record could then never match the merge tree.
    return (name.startswith("_") and name.endswith((".py", ".sh"))) or name.endswith(".awk")


def members(files, gate):
    """files: {name: bytes} of hooks/gates' top-level regular files -> sorted member names."""
    own = [n for n in (gate + ".sh", gate + ".py") if n in files]
    run = ["_run.py"] if "_run.py" in files else []
    picked, todo = set(own + run), own + run
    shared = {n: re.compile(rb"(?<![A-Za-z0-9_-])" + re.escape(os.fsencode(os.path.splitext(n)[0])) + rb"(?![A-Za-z0-9_-])")
              for n in files if _shared(n)}
    while todo:
        text = files[todo.pop()]
        for n, word in shared.items():
            if n not in picked and word.search(text):
                picked.add(n)
                todo.append(n)
    return sorted(picked)


def digest(files, names):
    h = hashlib.sha256()
    for n in names:
        h.update(os.fsencode(n) + b"\0" + hashlib.sha256(files[n]).hexdigest().encode() + b"\n")
    return h.hexdigest()


def from_dir(d):
    out = {}
    for n in os.listdir(d):
        p = os.path.join(d, n)
        if os.path.isfile(p) and not os.path.islink(p):
            with open(p, "rb") as f:
                out[n] = f.read()
    return out


def from_rev(rev):
    # ls-tree of "hooks/gates/" lists that dir's entries; a symlink (mode 120000) or a dir is skipped,
    # as from_dir skips them. --full-tree: the path is from the repo top, not the cwd.
    ls = subprocess.run(["git", "ls-tree", "-z", "--full-tree", rev, "hooks/gates/"], capture_output=True)
    if ls.returncode != 0:
        sys.stderr.write("gate_closure: git ls-tree %s failed: %s" % (rev, ls.stderr.decode(errors="replace")))
        sys.exit(1)
    out = {}
    for entry in filter(None, ls.stdout.split(b"\0")):
        meta, path = entry.split(b"\t", 1)
        mode, kind, sha = meta.split()
        if kind != b"blob" or mode == b"120000":
            continue
        blob = subprocess.run(["git", "cat-file", "blob", sha.decode()], capture_output=True)
        if blob.returncode != 0:
            sys.stderr.write("gate_closure: git cat-file %s failed\n" % sha.decode())
            sys.exit(1)
        out[os.fsdecode(os.path.basename(path))] = blob.stdout  # surrogate-escaped, as os.listdir gives
    return out


def closure(files, gate):
    return digest(files, members(files, gate))


def wide(files, gate):
    """The replay cache's key part (GH #893): the gate's .sh and .py plus EVERY _*.py, _*.sh and *.awk file
    (_shared()), used or not.
    Wider than closure() on purpose: a stale cache row is a wrong verdict, so a name match that misses a file
    (a name built at run time) must not leave a changed file out of the key. __pycache__ is a dir: not read."""
    own = [n for n in (gate + ".sh", gate + ".py") if n in files]
    return digest(files, sorted(set(own) | {n for n in files if _shared(n)}))


def main(argv):
    show_files = "--files" in argv
    args = [a for a in argv if a != "--files"]
    if len(args) != 3 or args[0] not in ("--dir", "--rev") or args[2] not in GATES:
        sys.stderr.write((__doc__ or "").split("\n\n")[1] + "\n")
        return 2
    files = from_dir(args[1]) if args[0] == "--dir" else from_rev(args[1])
    names = members(files, args[2])
    print("\n".join(names) if show_files else digest(files, names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
