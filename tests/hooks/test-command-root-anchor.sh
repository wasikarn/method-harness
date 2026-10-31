#!/usr/bin/env bash
# Behavioral tests for hooks/session/command-root-anchor.sh, including GH #783:
# a stale sessionstart-hook-<n>.sh from before a resume must not override the
# fresh MH_PLUGIN_ROOT when Claude Code sources the env files in numeric order.
# Run standalone: bash tests/hooks/test-command-root-anchor.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
HOOK="$ROOT/hooks/session/command-root-anchor.sh"

pass=0
fail=0
FIXTURE=$(mktemp -d)
trap 'tmp_delete "$FIXTURE"' EXIT

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

# source_all <dir>: source every sessionstart-hook-*.sh in numeric order, print MH_PLUGIN_ROOT.
source_all() {
  (unset MH_PLUGIN_ROOT
   # shellcheck disable=SC1090  # fixture env files are generated per row
   for f in $(cd "$1" && ls sessionstart-hook-*.sh | sort -t- -k3 -n); do . "$1/$f"; done
   printf '%s' "${MH_PLUGIN_ROOT:-}")
}

echo "=== command-root-anchor ==="

d="$FIXTURE/fresh"; mkdir "$d"
CLAUDE_PLUGIN_ROOT=/new/root/ CLAUDE_ENV_FILE="$d/sessionstart-hook-0.sh" bash "$HOOK"; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ "$(cat "$d/sessionstart-hook-0.sh")" = "export MH_PLUGIN_ROOT=/new/root" ] && ok=0
check "fresh dir: one export appended, trailing slash stripped" "$ok"

d="$FIXTURE/stale"; mkdir "$d"
printf 'export FOO=keep\nexport MH_PLUGIN_ROOT=/old/root\n# export MH_PLUGIN_ROOT=commented\n' > "$d/sessionstart-hook-10.sh"
printf 'export MH_PLUGIN_ROOT=/old/self\n' > "$d/sessionstart-hook-9.sh"
printf 'export MH_PLUGIN_ROOT=/link/target\n' > "$FIXTURE/target.sh"
ln -s "$FIXTURE/target.sh" "$d/sessionstart-hook-11.sh"
printf 'export MH_PLUGIN_ROOT=/other\n' > "$d/other-hook-12.sh"
CLAUDE_PLUGIN_ROOT=/new/root CLAUDE_ENV_FILE="$d/sessionstart-hook-9.sh" bash "$HOOK"; rc=$?
check "stale dir: exit 0" "$rc"
ok=1; [ "$(printf 'export FOO=keep\n# export MH_PLUGIN_ROOT=commented\n')" = "$(cat "$d/sessionstart-hook-10.sh")" ] && ok=0
check "stale sibling: MH_PLUGIN_ROOT line removed, other lines byte for byte" "$ok"
rm "$d/sessionstart-hook-11.sh"  # symlink checked below; drop it so source_all sees real files only
ok=1; [ "$(source_all "$d")" = "/new/root" ] && ok=0
check "sourcing every file in numeric order gives the new root" "$ok"
ok=1; [ "$(printf 'export MH_PLUGIN_ROOT=/old/self\nexport MH_PLUGIN_ROOT=/new/root\n')" = "$(cat "$d/sessionstart-hook-9.sh")" ] && ok=0
check "own CLAUDE_ENV_FILE only appended to" "$ok"
ok=1; [ "$(cat "$FIXTURE/target.sh")" = "export MH_PLUGIN_ROOT=/link/target" ] && ok=0
check "symlinked sibling's target untouched" "$ok"
ok=1; [ "$(cat "$d/other-hook-12.sh")" = "export MH_PLUGIN_ROOT=/other" ] && ok=0
check "non-matching file name untouched" "$ok"

d="$FIXTURE/unset"; mkdir "$d"
printf 'export MH_PLUGIN_ROOT=/old/root\n' > "$d/sessionstart-hook-10.sh"
env -u CLAUDE_PLUGIN_ROOT CLAUDE_ENV_FILE="$d/sessionstart-hook-9.sh" bash "$HOOK"; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ ! -e "$d/sessionstart-hook-9.sh" ] && [ "$(cat "$d/sessionstart-hook-10.sh")" = "export MH_PLUGIN_ROOT=/old/root" ] && ok=0
check "unset CLAUDE_PLUGIN_ROOT: exit 0, nothing changed" "$ok"
env -u CLAUDE_ENV_FILE CLAUDE_PLUGIN_ROOT=/new/root bash "$HOOK"; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ "$(cat "$d/sessionstart-hook-10.sh")" = "export MH_PLUGIN_ROOT=/old/root" ] && ok=0
check "unset CLAUDE_ENV_FILE: exit 0, nothing changed" "$ok"

echo "command-root-anchor: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
