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
#                   secret-scan, Write/Edit text) under ${CLAUDE_CONFIG_DIR:-~/.claude}/projects;
#                   `--replay all` takes the whole pool. A whole-pool run with no --slug writes a
#                   replay record (GH #891) that scripts/merge-pr.sh and sync-pr-head.sh need for a gate change.
#                   Only Bash tool_use blocks (Write/Edit for secret-scan) are read: no ctx_* payloads
#   --slug S        read only that transcript dir; refused unless it is this project's slug
#                   or one of its worktrees' (<slug>--claude-worktrees-*)
#   --fuzz-seed S   add seeded mutations of the corpus
#   --runner R      auto (default): fork mode when both wrappers are byte-identical, else bash;
#                   fork: fork mode or exit 2;
#                   bash: every command through `bash <gate>.sh` (GH #889)
#   --cache         keep the OLD side's results in $GATE_REPLAY_CACHE_DIR (default
#                   ~/.cache/mh/gate-replay-cache) and reuse them (GH #893). For review-round replays
#                   only: a cached run never writes a replay record. Off by default.
#   --no-cache      the default, and it beats --cache. The replay before merge runs with it.
# Exit: 0 no diffs, 1 diffs or slower commands (GH #890), 2 usage error or refusal.
# Replay record (GH #891): $GATE_REPLAY_RECORD_DIR (default ~/.cache/mh/gate-replay)/<gate>-<closure>.json,
# <closure> being scripts/_lib/gate_closure.py's hash of the NEW side. Counts only, never command text;
# written with diffs too (the operator explains them on the PR). Local state, never committed.
# Fork mode (GH #889) loads python once per side and forks per command; every diff it finds, and
# every command over half the gate's deadline, is re-run through bash, and only bash's result counts.
# Both sides write their journal rows to a temp file (MH_GATE_JOURNAL_PATH) under a temp HOME, so
# the operator's real gate journal is never touched; the temp dir is deleted at exit through scripts/_lib/tmp_delete.py.
# It runs at the lowest CPU priority and never takes the gauntlet's queue: holding it, a
# 28-min replay kept every push waiting (2026-10-27).
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
usage() { sed -n '5,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cases="" replay=0 slug="" seed="" runner=auto cache_flags=()
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cases) [ $# -ge 2 ] || usage; cases="$2"; shift 2 ;;
    --replay) [ $# -ge 2 ] || usage; replay="$2"; shift 2 ;;
    --slug) [ $# -ge 2 ] || usage; slug="$2"; shift 2 ;;
    --fuzz-seed) [ $# -ge 2 ] || usage; seed="$2"; shift 2 ;;
    --runner) [ $# -ge 2 ] || usage; runner="$2"; shift 2 ;;
    --cache|--no-cache) cache_flags+=("$1"); shift ;;
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
case "$runner" in auto|fork|bash) : ;; *) echo "gate-differential: --runner takes auto, fork or bash" >&2; exit 2 ;; esac
case "$replay" in all) : ;; ''|*[!0-9]*) echo "gate-differential: --replay takes a number or all" >&2; exit 2 ;; esac

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

# Yield the CPU to peers' gauntlets instead of queueing behind them; children inherit it.
renice -n 19 -p $$ >/dev/null

tmp=$(mktemp -d) || exit 2
[ -n "$tmp" ] && [ -d "$tmp" ] || { echo "gate-differential: mktemp failed" >&2; exit 2; }
cleanup() { [ -n "$tmp" ] && [ -d "$tmp" ] && tmp_delete "$tmp"; }
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
  --fixtures "$ROOT/tests/hooks/fixtures" --runner "$runner"
[ -n "$cases" ] && set -- "$@" --cases "$cases"
[ -n "$slug" ] && set -- "$@" "--slug=$slug"
[ -n "$seed" ] && set -- "$@" --fuzz-seed "$seed"
[ ${#cache_flags[@]} -gt 0 ] && set -- "$@" "${cache_flags[@]}"
python3 "$ROOT/scripts/_lib/gate-differential.py" "$@"
