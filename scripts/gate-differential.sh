#!/usr/bin/env bash
# gate-differential.sh (GH #411): run the same corpus through an OLD and a NEW copy of one gate and
# compare (exit code, stdout, stderr, journal rows). Prints diff classes with counts and at most 3
# sample commands per class (100 chars, secret-scan patterns redacted), never raw transcript text.
#
# Usage: scripts/gate-differential.sh [options] OLD [NEW] GATE
#   OLD   a gates dir (holding <gate>.sh/.py and their _*.py siblings) or a git ref (hooks/gates at it)
#   NEW   a gates dir; default: this checkout's hooks/gates
#   GATE  irrecoverable | subagent-git-guard | secret-scan
# Options:
#   --cases FILE    one command per line, replacing the committed fixtures
#   --replay N      add N commands sampled from THIS project's transcripts (Bash commands; for
#                   secret-scan, Write/Edit text) under ${CLAUDE_CONFIG_DIR:-~/.claude}/projects
#   --slug S        read only that transcript dir; refused unless it is this project's slug
#                   or one of its worktrees' (<slug>--claude-worktrees-*)
#   --fuzz-seed S   add seeded mutations of the corpus
# Exit: 0 no diffs, 1 diffs, 2 usage error or refusal.
# Both sides write their journal rows to a temp file (MH_GATE_JOURNAL_PATH) under a temp HOME, so
# the operator's real gate journal is never touched; the temp dir is trashed at exit.
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cases="" replay=0 slug="" seed=""
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cases) [ $# -ge 2 ] || usage; cases="$2"; shift 2 ;;
    --replay) [ $# -ge 2 ] || usage; replay="$2"; shift 2 ;;
    --slug) [ $# -ge 2 ] || usage; slug="$2"; shift 2 ;;
    --fuzz-seed) [ $# -ge 2 ] || usage; seed="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "gate-differential: unknown option $1" >&2; usage ;;
    *) pos+=("$1"); shift ;;
  esac
done
case ${#pos[@]} in
  2) old="${pos[0]}" new="$ROOT/hooks/gates" gate="${pos[1]}" ;;
  3) old="${pos[0]}" new="${pos[1]}" gate="${pos[2]}" ;;
  *) usage ;;
esac
case "$gate" in irrecoverable|subagent-git-guard|secret-scan) : ;; *) echo "gate-differential: unknown gate $gate" >&2; usage ;; esac
case "$replay" in ''|*[!0-9]*) echo "gate-differential: --replay takes a number" >&2; exit 2 ;; esac

# Transcript slug: Claude Code names a project dir after the session cwd with every
# non-alphanumeric character as "-". A worktree's dir is the main checkout's slug + "--claude-worktrees-...".
common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir) || exit 2
own_slug=$(cd -P "$common/.." && pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
if [ -n "$slug" ]; then
  case "$slug" in
    */*|*..*) echo "gate-differential: refusing --slug with / or .. in it" >&2; exit 2 ;;
    "$own_slug"|"$own_slug--claude-worktrees-"*) : ;;
    *) echo "gate-differential: refusing --slug outside this project (want $own_slug or its worktrees)" >&2; exit 2 ;;
  esac
fi

tmp=$(mktemp -d) || exit 2
[ -n "$tmp" ] && [ -d "$tmp" ] || { echo "gate-differential: mktemp failed" >&2; exit 2; }
cleanup() { [ -n "$tmp" ] && [ -d "$tmp" ] && python3 "$ROOT/tests/_lib/tmp_delete.py" "$tmp"; }
trap cleanup EXIT

if [ ! -d "$old" ]; then
  # A git ref: extract hooks/gates at it (the gates import their _*.py siblings).
  git -C "$ROOT" rev-parse --verify --quiet "$old^{commit}" >/dev/null \
    || { echo "gate-differential: OLD is neither a dir nor a git ref: $old" >&2; exit 2; }
  mkdir -p "$tmp/ref"
  git -C "$ROOT" archive "$old" hooks/gates | tar -x -C "$tmp/ref" || exit 2
  old="$tmp/ref/hooks/gates"
fi
for d in "$old" "$new"; do
  [ -r "$d/$gate.sh" ] || { echo "gate-differential: no $gate.sh in $d" >&2; exit 2; }
done

set -- --old "$old" --new "$new" --gate "$gate" --tmp "$tmp" --replay "$replay" \
  --projects "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "--own-slug=$own_slug" \
  --fixtures "$ROOT/tests/hooks/fixtures"
[ -n "$cases" ] && set -- "$@" --cases "$cases"
[ -n "$slug" ] && set -- "$@" "--slug=$slug"
[ -n "$seed" ] && set -- "$@" --fuzz-seed "$seed"
python3 "$ROOT/scripts/_lib/gate-differential.py" "$@"
