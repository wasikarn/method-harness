#!/usr/bin/env bash
# Gate: block irrecoverable Bash patterns. PreToolUse JSON on stdin; exit 2 blocks.
set -uo pipefail

# Fast path: skip the python3 cold-start when no deny can match. Every deny in
# irrecoverable.py dispatches on an argv0 in the case list below; wrappers never
# hide it. Quote/backslash stripping exposes r""m -> rm, the whitespace-collapsed
# variant a backslash-newline split argv0, and any bare $ or backtick may be a
# zero-width splice (gi$(true)t) so it defers to python on its own. False
# positives just spawn python (safe direction). GH #134: CC never \u-escapes $.
_input="$(cat)"
# A JSON-escaped backslash (two backslashes) is a literal backslash, not the start of a \n or \t
# escape, so mark the pair first; the shell reads backslash-t as a plain t (fuzz sweep 2026-10-01).
_bs=$'\001'
_norm="$(printf '%s' "$_input" | sed "s/\\\\\\\\/$_bs/g; s/\\\\[nt]/ /g" | tr -s '[:space:]' ' ' | tr -d "\"'$_bs\\\\")"
_norm_nows="$(printf '%s' "$_norm" | tr -d '[:space:]')"
_has_subst=0
case "$_input" in *'`'*|*'$'*) _has_subst=1 ;; esac
# GH #309: a brace group can hide any word, argv0 included ("r{m,} -rf" runs rm, "{f,\"x y\"}ind" runs
# find), so a command with a brace group that can expand (a "," or ".." at its own level, nested groups
# included: "r{{x},m}", and a stray "}" before the comma: "{A=1}},git}") defers to python. brace-route.awk
# does the counting the way bash scans (it skips the payload's own JSON objects). "${var}" is a plain
# parameter, "{x}" and f"{n}" expand to nothing: both stay on the fast path. A missing awk file, or an
# awk that fails or prints nothing, defers to python, never allows.
case "$0" in */*) _gdir="${0%/*}" ;; *) _gdir=. ;; esac
_awk="$_gdir/brace-route.awk"
# The awk bounds its own work (a payload over its budget prints a hit), so a heredoc of f-strings up to 100000
# characters stays on the fast path when no group can expand; a bigger payload with a "{" goes to python (awk copies
# the line on every substr, so its cost grows with the payload) and python's own length cap decides it.
if { [ "${#_input}" -gt 100000 ] && case "$_input" in *'{'*) true ;; *) false ;; esac; } || [ ! -r "$_awk" ] || ! command -v awk >/dev/null 2>&1; then
  _has_subst=1
else
  if _nbrace="$(printf '%s' "$_input" | awk -f "$_awk")" && [ -n "$_nbrace" ]; then
    case $_nbrace in *[!0$'\n']*) _has_subst=1 ;; esac  # any count but 0 (awk prints digits only)
  else
    _has_subst=1
  fi
fi
# GH #592: `.` is source's other spelling. A "." word in command position (after a blank, the JSON key's
# ":", a separator or a case arm's ")"), ended by a blank or a glued redirection (.<in x.sh, .&>f x.sh),
# defers to python; a "." inside a word (done. next, ./x.sh) stays on the fast path.
case "$_norm" in
  *[[:space:]:\;\&\|\(\)\{]'.'[[:space:]\<\>\&]*) _has_subst=1 ;;
esac
case "$_norm$_norm_nows" in
  *rm*|*find*|*git*|*gh*|*dd*|*mysql*|*psql*|*sqlite3*|*mariadb*|*dropdb*|*mongo*|*redis*|*rsync*|*claude*|*mkfs*|*mke2fs*|*chmod*|*source*) : ;;  # candidate -> python
  *) [ "$_has_subst" -eq 1 ] || exit 0 ;;                          # no destructive token possible -> allow (unless obfuscated)
esac

# Portability guard (#93): announced fail-open without python3 (rc=127 would otherwise block every git/rm).
if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — irrecoverable-pattern gate cannot run; allowing (install python3 to restore deny coverage)" >&2
  exit 0
fi

_py="$_gdir/irrecoverable.py"
# Missing sibling: same fail-closed exit 2 python3 would give, cleaner diagnostic.
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script irrecoverable.py missing or unreadable — failing closed" >&2
  exit 2
fi

_run="$_gdir/_run.py"  # imports the gate so its bytecode comes from __pycache__ (a script is recompiled every run)
if [ ! -r "$_run" ]; then
  echo "[mh:gate] internal error: sibling script _run.py missing or unreadable — failing closed" >&2
  exit 2
fi
printf '%s' "$_input" | python3 -S "$_run" irrecoverable  # -S: no site import, ~6 ms per call; the gates use the stdlib only
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "[mh:gate] internal error (rc=$rc) — failing closed" >&2
  exit 2
fi
exit "$rc"
