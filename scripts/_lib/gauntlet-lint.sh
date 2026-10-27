#!/usr/bin/env bash
# gauntlet-lint.sh — the gauntlet's lint layer, shared by scripts/run-gauntlet.sh (every tracked file)
# and git-hooks/pre-push (only the files a push changes, GH #735). Source it, then, from the root of the
# tree to lint, pipe it the repo-relative paths, one per line:
#   git ls-files | run_lint
# Checks: bash -n and shellcheck -S warning (when installed) on *.sh and git-hooks/*, py_compile on
# *.py and a JSON parse on *.json (the audit's known-bad fixtures, invalid on purpose, are skipped, as
# in pre-commit), and the home-path ban on every listed file. Paths that are not regular files are
# dropped. Exit 1 when any check fails. Bash 3.2.
_GAUNTLET_LINT_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

existing() { local f; while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done; return 0; }

# _lint_pick <awk regex> <paths>: the paths matching the regex, outside the known-bad fixtures, NUL-separated.
# Write a literal dot as [.]: awk -v processes escapes, so '\.sh$' arrives as '.sh$' (any char).
_lint_pick() {
  printf '%s\n' "$2" | awk -v re="$1" 'NF && $0 ~ re && $0 !~ /^tests\/skills\/harness-audit\/known-bad\//' | tr '\n' '\0'
}

run_lint() {
  local rc=0 all home_hits
  all=$(existing)
  # Lint runs beside 4 test jobs; P stays low because GH #158 timing rows flake under load.
  # Without -x or a .shellcheckrc, shellcheck checks each file alone, so batching keeps its verdicts.
  # bash -n stays one file per call: `bash -n a b` checks only a (b is its $1).
  # -r: GNU xargs would otherwise run each command once on an empty list (shellcheck then fails).
  _lint_pick '[.]sh$|^git-hooks/' "$all" | xargs -0 -r -n 1 -P 2 bash -n || rc=1
  if command -v shellcheck >/dev/null; then
    _lint_pick '[.]sh$|^git-hooks/' "$all" | xargs -0 -r -n 60 -P 2 shellcheck -S warning || rc=1
  fi
  # One python process for every .py and .json, instead of one per file.
  _lint_pick '[.]py$|[.]json$' "$all" | xargs -0 -r python3 "$_GAUNTLET_LINT_LIB/lint-files.py" || rc=1
  # Home-path ban on every listed file (pre-commit only sees staged blobs).
  # Env goes on xargs, not after it: BSD xargs treats `LC_ALL=C` as the command (exit 127,
  # once swallowed by 2>/dev/null). Hits are captured because xargs exits 123 on any batch
  # where grep found nothing, which an `if` on the pipeline would read as a miss.
  home_hits=$(printf '%s\n' "$all" | awk NF | tr '\n' '\0' \
       | LC_ALL=C xargs -0 -r /usr/bin/grep -alE '/Users/[A-Za-z]|-Users-[A-Za-z]' 2>/dev/null || true)
  if [ -n "$home_hits" ]; then
    printf '%s\n' "$home_hits"; echo "hardcoded home path in tracked file(s) above"; rc=1
  fi
  return "$rc"
}
