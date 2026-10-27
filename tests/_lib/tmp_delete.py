#!/usr/bin/env python3
"""tmp_delete.py <path>... -- permanently delete a test's or script's own temp dirs and files.

Tier 1 of the delete rule in docs/reference/repo-gotchas.md: a self-made mktemp dir or a file
inside one is deleted for good here instead of going through `trash`, which put ~20k items a
day into ~/.Trash and kept Finder busy (GH #724). Real files still go to `trash`.

Every argument is checked before anything is deleted. One refused argument means a message on
stderr, exit 2, and nothing deleted at all. Refused:
- an empty argument (`trash ""` once moved the repo's working tree to the Trash);
- `/`, the account's real home or any ancestor of it (read from the password database, not
  $HOME, because tests export a fake HOME under the temp dir and must still clean it up);
- the system temp dir itself or any ancestor of it (/tmp, and on macOS the per-user dir from
  `getconf DARWIN_USER_TEMP_DIR`): an earlier draft that allowed all of /private/var/folders
  deleted files from $TMPDIR itself;
- any path whose location is not strictly under one of those system temp dirs. $TMPDIR is never
  a root of its own: TMPDIR=/usr would otherwise make /usr deletable. A test that exports TMPDIR
  as its own mktemp dir is still covered, since that dir sits under a system temp dir. The repo
  working tree is never a root: deleting there must stay recoverable. A tests/_lib/harness.sh
  _HARNESS_ROOT is a mktemp dir, so it is covered.
A path that does not exist (after the root check) is a no-op success, so a cleanup can run twice.
A symlink is removed as a link; its target is never touched, and the parent directory's realpath
is what must sit under a root, so a link cannot steer the delete outside it.
"""
import os
import pwd
import shutil
import subprocess
import sys


def under(path, root):
    return path != root and os.path.commonpath([path, root]) == root


def main(args):
    home = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    system = {os.path.realpath("/tmp")}
    if sys.platform == "darwin":  # the per-user temp dir, from the OS, not the test-settable env
        d = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        if d:
            system.add(os.path.realpath(d))

    if not args:
        print("tmp_delete: no path given", file=sys.stderr)
        return 2
    targets, refused = [], []
    for a in args:
        if not a:
            refused.append("an empty argument")
            continue
        p = os.path.abspath(a)
        # Resolve the parent only, so a symlink argument is judged by where the link itself lives.
        loc = os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))
        if loc == "/" or loc == home or under(home, loc):
            refused.append(f"{a!r} (/, the home, or an ancestor of it)")
        elif any(loc == r or under(r, loc) for r in system):
            refused.append(f"{a!r} (the system temp dir or an ancestor of it)")
        elif not any(under(loc, r) for r in system):
            refused.append(f"{a!r} (not strictly under a temp root: {sorted(system)})")
        else:
            targets.append(loc)
    if refused:
        for r in refused:
            print(f"tmp_delete: refused {r}; nothing deleted", file=sys.stderr)
        return 2

    for loc in targets:
        if os.path.islink(loc) or os.path.isfile(loc):
            os.unlink(loc)
        elif os.path.isdir(loc):
            shutil.rmtree(loc)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
