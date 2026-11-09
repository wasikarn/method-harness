# deep-audit: step 3 citation check

`SKILL.md` step 3 holds the command; this is the detail. The script is `scripts/_lib/citation_exists.py`
(docstring and tests: `tests/scripts/test-citation-exists.sh`).

## Inputs

- `$VERDICT`: the validated JSON `check-verdict.py` printed on exit 0, saved to a file outside the repo (a
  fresh `mktemp`). The script reads every `path:line` and commit SHA in it, in `findings[]` and `checked[]`.
- `$DIFFPATHS`: `git diff --name-only <first-sha>^..HEAD`, saved the same way. A path listed there counts as
  present only when no file is on disk, so a file the session deleted still resolves; the line check still
  runs for a file that exists.
- `--root`: the repo root, and one more per repo the scope named in step 1. A cite into a repo with no
  `--root` can come back `missing`.

## Labels

- `resolved`: the file exists under a root and the line is in range, or the commit exists, or the path is in
  `$DIFFPATHS`.
- `missing`: the first directory exists under a root but the file does not, or the line is past the end.
- `ambiguous-or-outside`: a bare name matching zero or several files, a path outside every root, a `..`
  segment, or a commit found in no root.

## Report

The output says "citations exist: N of M resolved", never "verified": the script confirms that a file, a line
in range or a commit is there, not that the claim built on it is true. It reports the line of the input where
a bad cite sits, not the finding it belongs to, so map each `missing` cite to its finding by hand and flag
that finding for a recheck. `missing` is not proof of fabrication.

## What it never does

It is report-only. It never changes `pass`, never drops a finding, and its exit code is not a verdict: 0
whenever it ran, 2 on a usage error (no usable `--root`, unreadable input). On exit 2, note it in the report
and carry on with the audit.
