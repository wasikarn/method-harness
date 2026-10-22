#!/usr/bin/env bash
# mh:ste-lint — word counter self-test, plus the target-selection and
# report-only invariants Codex flagged during plan review.
# Run standalone: bash tests/skills/test-ste-lint.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/skills/design/ste-lint/scripts/ste-lint.py"
FAIL=0

python3 "$SCRIPT" --selftest || { echo "FAIL: ste-lint.py selftest"; FAIL=1; }

TMP="$(mktemp -d)"
OUTSIDE="$TMP-outside.md"
trap 'trash "$TMP" "$OUTSIDE" 2>/dev/null || true' EXIT
(
  cd "$TMP" || exit 1
  git init -q
  git config user.email t@t.test
  git config user.name t

  # Zero changed files: a clean commit has no findings, not an error.
  printf 'hello\n' > clean.md
  git add clean.md && git commit -q -m init
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q '"files": \[\]' || { echo "FAIL: zero-changed-files, got: $out"; exit 1; }

  # Odd filenames: a space and a leading dash, both untracked.
  printf 'Do not use this; it is not allowed.\n' > "has space.md"
  printf 'Do not use this; it is not allowed.\n' > ./-dashfile.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q 'has space.md' || { echo "FAIL: space-filename not scanned"; exit 1; }
  echo "$out" | /usr/bin/grep -q -- '-dashfile.md' || { echo "FAIL: dash-filename not scanned"; exit 1; }

  # Symlink escaping the repo root must not be followed.
  printf 'Do not use this; it is not allowed.\n' > "$OUTSIDE"
  ln -s "$OUTSIDE" escape.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q '"path": "escape.md"' && { echo "FAIL: escaping symlink was scanned"; exit 1; }

  # Symlink staying inside the repo root must be followed like a normal file.
  printf 'Do not use this; it is not allowed.\n' > real-inside.md
  ln -s real-inside.md inside-link.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q '"path": "inside-link.md"' || { echo "FAIL: in-repo symlink was not scanned"; exit 1; }

  # Unreadable file: reported as an error (exit 2), not a crash.
  printf 'Do not use this; it is not allowed.\n' > unreadable.md
  chmod 000 unreadable.md
  python3 "$SCRIPT" unreadable.md --json > /dev/null 2>&1
  code=$?
  chmod 644 unreadable.md
  [ "$code" -eq 2 ] || { echo "FAIL: unreadable file expected exit 2, got $code"; exit 1; }

  # A semicolon inside a fenced code block is never reported; the same
  # semicolon in prose is.
  cat > mixed.md <<'EOF'
Do not use this; it is not allowed.

```
echo "a;b"
```
EOF
  out=$(python3 "$SCRIPT" mixed.md --json)
  echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = [f['line'] for f in d['files'][0]['confirmed'] if f['rule'] == '8.1']
assert lines == [1], lines
" || { echo "FAIL: code-block semicolon leaked into findings"; exit 1; }

  # docs/METHODOLOGY.md is frozen: its byte cap fights Rule 4.2 directly, so a
  # default sweep must never scan it even when dirty.
  mkdir -p docs
  printf 'Do not use this; it is not allowed.\n' > docs/METHODOLOGY.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q 'METHODOLOGY.md' && { echo "FAIL: docs/METHODOLOGY.md was scanned by default sweep"; exit 1; }

  # Report-only: scanning never changes the target file's bytes.
  before=$(shasum -a 256 mixed.md)
  python3 "$SCRIPT" mixed.md > /dev/null
  after=$(shasum -a 256 mixed.md)
  [ "$before" = "$after" ] || { echo "FAIL: mixed.md mutated by a report-only run"; exit 1; }

  # Ancestor-directory symlink escape: the leaf file is a plain tracked
  # file, but a directory further up the path is later replaced with a
  # symlink pointing outside the repo. realpath() must still catch this
  # even though the leaf itself was never a symlink (the bug this replaces
  # only checked os.path.islink() on the leaf, not each ancestor segment).
  mkdir -p "$OUTSIDE-dir"
  printf 'Outside secret; must not scan.\n' > "$OUTSIDE-dir/child.md"
  mkdir -p replaced
  printf 'Placeholder; will be replaced.\n' > replaced/child.md
  git add replaced/child.md && git commit -q -m "add replaced dir"
  trash replaced
  ln -s "$OUTSIDE-dir" replaced
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q 'replaced/child.md' && { echo "FAIL: ancestor-symlink escape was scanned"; exit 1; }
  true
) || FAIL=1

TMP2="$(mktemp -d)"
trap 'trash "$TMP" "$OUTSIDE" "$OUTSIDE-dir" "$TMP2" 2>/dev/null || true' EXIT
(
  cd "$TMP2" || exit 1

  # A git repo with no HEAD yet (no commits) must still find staged files,
  # not silently report "clean" because `git diff ... HEAD` has nothing to
  # diff against.
  git init -q
  git config user.email t@t.test
  git config user.name t
  printf 'Do not use this; it is not allowed.\n' > staged.md
  git add staged.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q '"path": "staged.md"' || { echo "FAIL: staged.md not found in a repo with no HEAD yet"; exit 1; }

  # An explicit path that does not exist is a tool error (exit 2), never a
  # silent "clean" (files: [], exit 0).
  python3 "$SCRIPT" does-not-exist.md --json > /dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || { echo "FAIL: nonexistent explicit path expected exit 2, got $code"; exit 1; }

  # An explicit directory that can't be listed (chmod 000) is a tool error
  # (exit 2), never a silent "clean".
  mkdir noaccess
  printf 'Do not use this; it is not allowed.\n' > noaccess/x.md
  chmod 000 noaccess
  python3 "$SCRIPT" noaccess --json > /dev/null 2>&1
  code=$?
  chmod 755 noaccess
  [ "$code" -eq 2 ] || { echo "FAIL: unreadable directory expected exit 2, got $code"; exit 1; }

  # A same-tree symlink alias that resolves to a frozen path must not bypass
  # the frozen-dir exclusion just because its own tracked name doesn't start
  # with a frozen prefix (deep-audit finding: is_frozen() only checked the
  # lexical git-relative name, never the resolved target).
  trash noaccess 2>/dev/null || true  # leftover fixture from the check above
  mkdir -p docs/research
  printf 'Frozen; must not scan.\n' > docs/research/real.md
  git add docs/research/real.md && git commit -q -m "add frozen research file"
  ln -s docs/research/real.md alias.md
  out=$(python3 "$SCRIPT" --json)
  echo "$out" | /usr/bin/grep -q '"path": "alias.md"' && { echo "FAIL: symlink alias into a frozen dir was scanned"; exit 1; }
  true
) || FAIL=1

TMP3="$(mktemp -d)"
trap 'trash "$TMP" "$OUTSIDE" "$OUTSIDE-dir" "$TMP2" "$TMP3" 2>/dev/null || true' EXIT
(
  # Running outside a git repository entirely is a tool error (exit 2),
  # never an uncaught traceback (deep-audit finding: repo_root() propagated
  # git's CalledProcessError, crashing with the interpreter's default exit 1).
  cd "$TMP3" || exit 1
  python3 "$SCRIPT" --json > /dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || { echo "FAIL: outside a git repo expected exit 2, got $code"; exit 1; }
) || FAIL=1

TMP4="$(mktemp -d)"
trap 'trash "$TMP" "$OUTSIDE" "$OUTSIDE-dir" "$TMP2" "$TMP3" "$TMP4" 2>/dev/null || true' EXIT
(
  # --no-advisory hides advisory lines but keeps confirmed ones and the exit code;
  # a long sentence's echoed excerpt is capped so a directory scan stays readable.
  cd "$TMP4" || exit 1
  git init -q
  long="Remove the cover; $(printf 'then check the bolt %.0s' $(seq 1 30))and the colour of the panel."
  printf '%s\n' "$long" > doc.md
  full=$(python3 "$SCRIPT" --mode procedural doc.md); c1=$?
  quiet=$(python3 "$SCRIPT" --mode procedural --no-advisory doc.md); c2=$?
  /usr/bin/grep -q '\[advisory\]' <<<"$full" || { echo "FAIL: fixture produced no advisory line"; exit 1; }
  /usr/bin/grep -q '\[advisory\]' <<<"$quiet" && { echo "FAIL: --no-advisory still prints advisory lines"; exit 1; }
  /usr/bin/grep -q '\[confirmed\]' <<<"$quiet" || { echo "FAIL: --no-advisory dropped confirmed lines"; exit 1; }
  [ "$c1" -eq 1 ] && [ "$c2" -eq 1 ] || { echo "FAIL: exit codes $c1/$c2, expected 1/1"; exit 1; }
  maxlen=$(/usr/bin/grep 'words (limit' <<<"$full" | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$maxlen" -gt 0 ] && [ "$maxlen" -le 200 ] || { echo "FAIL: word-count finding line is $maxlen chars, excerpt not capped"; exit 1; }
) || FAIL=1

[ "$FAIL" -eq 0 ] && echo "PASS: test-ste-lint" || { echo "FAIL: test-ste-lint"; exit 1; }
