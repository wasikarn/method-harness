#!/usr/bin/env bash
# Gate: ask when an edit to an existing test file removes an assertion-
# shaped line, or adds a skip/disable marker that wasn't there before.
# METHODOLOGY.md Rule 4 ("write the failing test first, don't weaken it
# while fixing") had no backing mechanism anywhere — pure prose, the exact
# same-role-grades-its-own-work case CLAUDE.md's maker≠checker doctrine
# argues against trusting.
#
# Stateless by design: no session-phase marker exists (or should exist —
# building one just relocates the self-discipline problem onto remembering
# to set/clear it). The diff itself is the classifier, computed fresh per
# call, the same "prove it from content" shape db-write-gate.sh uses for
# SQL. New-file test creation needs no old-side assertion to remove, so it
# is silent by construction — no separate carve-out required.
#
# Known, deliberate gap: this catches a REMOVED assertion line, an ADDED
# skip marker, an ADDED always-false conditional/loop wrap around
# otherwise-unchanged content — `if`/`elif`/`while` opening on a bare
# `false`/`0`, or a `[ ]`/`[[ ]]`/bare-`test` numeric comparison that is
# itself statically false (`0 -eq 1`, `1 -eq 2`, `2 -ne 2`, any literal
# pair, not just 0/1) — a REDEFINED `check()` oracle (the call sites stay
# byte-identical, only the helper's own body changes), a DELETED final
# `[ "$fail" -eq 0 ]` exit-gate line (this repo's own test files, this
# gate's own included, all use it to turn an accumulated fail count into
# a real exit code), a duplicate assertion line reduced to fewer copies
# (multiset-tracked, not a plain line SET, so removing one of two
# identical lines is no longer invisible), and an assertion relocated into
# an inert HEREDOC body or a `: '...'` colon no-op block (both stripped
# before scanning, same "heredoc is inert data unless it feeds an
# interpreter" distinction `irrecoverable.sh` already uses
# — ported, not reinvented). A same-day deep-audit fresh-context check
# found the first version of this (2026-08-28, `if false` only)
# overclaimed: `elif false`, `while false`, `if [ 1 -eq 2 ]`, and bare
# `if test 0 -eq 1` all bypassed it silently — verified live, each is a
# real always-false wrap, same family as the original finding, just a
# different spelling. A later deep-audit pass (also 2026-08-28) found the
# oracle-redefinition, exit-gate-deletion, multiset-collapse, and
# heredoc/colon-noop-relocation gaps above; all four were vocabulary gaps
# in this same line-based diff, not cases that needed real control-flow
# analysis — closed the same way as the `elif`/`while` gap before them.
# Deliberately NOT flagged, and not a gap: `if [ 0 ]` / `if [[ false ]]`
# (single-operand tests) — bash treats a non-empty string as true regardless
# of its text, so both of those are always-TRUE, not a skip (verified live;
# matching them would be a false positive, not a closed gap).
# Still not detected, and these genuinely DO need real control-flow /
# reachability analysis rather than a vocabulary addition: moving an
# assertion into a function that is never called, a `case` statement with
# no matching branch, a `continue`/`return`/`exit` inserted immediately
# before the assertion in the same block, or a runtime-variable-gated skip
# (`if [ "$SKIP" = 1 ]`) — out of scope for a lightweight PreToolUse
# content-diff gate, a real residual, not claimed as covered.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found — test-integrity gate cannot run; allowing (install python3 to restore the ask)" >&2
  exit 0
fi

case $0 in */*) _gdir="${0%/*}" ;; *) _gdir=. ;; esac  # not $(dirname): saves a fork
_py="$_gdir/test-integrity.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script test-integrity.py missing or unreadable — allowing (test-integrity is ask-only, fails open)" >&2
  exit 0
fi

# Fast path (_silent_fastpath.sh): every PATH_RE branch needs "test" or "spec" in some case, and
# a "file_path" key with a non-string value (true, 5) makes PATH_RE.search raise, which asks, so
# both defer to python; anything else is a path PATH_RE cannot match, and python exits silently.
if [ -r "$_gdir/_silent_fastpath.sh" ] && . "$_gdir/_silent_fastpath.sh"; then
  mh_gate_run "$_py" $'[tT][eE][sS][tT]|[sS][pP][eE][cC]|"file_path"[ \t\n\r]*:[ \t\n\r]*[^"]'
fi
python3 -S "$_py"
