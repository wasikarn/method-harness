#!/usr/bin/env bash
# Gate: a subagent (agent_id in the PreToolUse payload) may not run a bare
# `git stash|reset|clean` -- repo-wide mutation on a tree the parent session
# (and any other subagent sharing it) is still working in (issue #135;
# 2026-09-28: worktree-per-session means this is now the parent session's own
# worktree rather than a tree shared with unrelated peer sessions, but a
# subagent still shares that ONE tree with its parent and siblings, so the
# same repo-wide-mutation risk applies). Main session (no agent_id) is
# untouched; `claude --agent` main
# sessions also lack agent_id, so agent_type is NOT the discriminant.
# irrecoverable.sh already denies the destructive forms (reset --hard, clean -f,
# checkout --, restore <path>) for every session; this gate only adds the three
# non-force verbs, for subagents. Coarse pattern match, not a sandbox: a quoted
# "git" is read (GH #344), but a second parse level (eval of an escaped quote)
# or a substitution that builds the word "git" is a non-goal, and a
# heredoc BODY line starting with "git stash" over-blocks (no heredoc parsing).
#
# Fast path (GH #326) skips python3 only on proof it would allow in silence. A bare "no agent_id
# substring" check is a bypass (GH #154: the key can be written with a \u escape). JSON's other
# escapes (\" \\ \/ \b \f \n \r \t) cannot make a letter or "_", so with neither agent_id nor \u
# in the raw text, a payload that also matches the plain-object regex below (ASCII, depth 2, no
# arrays) parses to a dict with no agent_id key: python exits 0, no output. Anything else runs
# python3 (malformed JSON keeps its stderr line). Keep `_input=$(cat)` on line 33: bash's NUL-byte
# warning names it. No "no git substring" shortcut: g\it serializes as g\\it (GH #317).
set -uo pipefail

# Portability guard (#93): announced fail-open when python3 is missing.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — subagent-git-guard gate cannot run; allowing (install python3 to restore the subagent git-guard rule)" >&2
  exit 0
fi

_input=$(cat)

# ${0%/*}, not $(dirname), saves a fork on every call.
case $0 in */*) _py="${0%/*}/subagent-git-guard.py" ;; *) _py=subagent-git-guard.py ;; esac
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script subagent-git-guard.py missing or unreadable — allowing (fail-safe = allow, same posture as this gate's own parse-error path)" >&2
  exit 0
fi

_s='"([ !#-[]|[]-~]|\\["\\/bfnrt])*"'                   # ASCII string, no \u
_w=$'[ \t\n\r]*'                                         # JSON whitespace only
_v="($_s|-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?|true|false|null)"
_o="[{]$_w($_s$_w:$_w$_v$_w(,$_w$_s$_w:$_w$_v$_w)*)?[}]"  # object of scalars
_v="($_v|$_o)"
_re="^${_w}[{]$_w($_s$_w:$_w$_v$_w(,$_w$_s$_w:$_w$_v$_w)*)?[}]$_w\$"
_no_agent_id() {
  local LC_ALL=C  # byte-wise match: ranges are ASCII, non-ASCII bytes fail
  case $_input in *agent_id*|*'\u'*) return 1 ;; esac
  [[ $_input =~ $_re ]]
}
_no_agent_id && exit 0

_run="${_py%subagent-git-guard.py}_run.py"
if [ ! -r "$_run" ]; then
  echo "[mh:gate] internal error: sibling script _run.py missing or unreadable — allowing (fail-safe = allow, same posture as this gate's own parse-error path)" >&2
  exit 0
fi
printf '%s' "$_input" | python3 -S "$_run" subagent-git-guard  # imports the gate so its bytecode comes from __pycache__; -S: skip site import
exit $?
