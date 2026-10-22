#!/usr/bin/env bash
# Gate: ask before CREATING a brand-new Claude Code settings file
# (.claude/settings.json, .claude/settings.local.json -- covers both the
# user-level ~/.claude/ and any project-level .claude/ dir, since both share
# that same basename shape), plus the real file a symlinked settings file in
# the config dir, project dir or cwd resolves to (a dotfiles repo's
# claude/settings.json).
#
# Why the asymmetry: an edit lands on a file a human has already reviewed at
# least once; a brand-new file introduces a whole unreviewed behavior surface
# with no prior review anchor. Same create-vs-modify split as the pre-commit
# new-file LOC gate (git-hooks/pre-commit), applied here at tool-call time via
# a plain existence check instead of at commit time via `git diff --diff-filter=A`.
#
# ASK, not DENY: creating a new settings file is reversible (it can be
# deleted), so this isn't the "irrecoverable set" DENY gates exist for.
#
# EDITING an existing settings file is also checked, but only for three
# security-relevant keys: `hooks` (a matt-side skill like
# git-guardrails-claude-code can instruct the model to merge a new entry into
# hooks.PreToolUse -- installing a hook this repo's own tamper-resistance
# gates never review), `enabledPlugins` (can flip this plugin's own enabled
# flag off), and `env` -- Claude Code injects a settings file's `env` block
# into the session AND the subprocesses it spawns (docs/reference/env-vars.md),
# so an edit to that key could silently set an escape-hatch var (see
# docs/reference/env-vars.md) without ever touching hooks/enabledPlugins directly. Every other key --
# statusLine, permissions, theme, etc. -- stays frictionless, matching this
# gate's own "an already-reviewed file needs no friction" philosophy for the
# ordinary case. The edit is reconstructed from the on-disk content plus the
# tool's own Write/Edit payload and compared key-by-key against the original;
# a change to any of the three keys, or content on either side that cannot be
# parsed as JSON, asks. Fail-toward-ask on the unverifiable case -- but this
# gate's outer exception handler still allows on a malformed top-level
# payload it cannot parse at all (an intentionally unchanged, pre-existing
# safety net for genuinely unexpected errors -- see the try/except structure
# below). A payload nested too deep for json.load (RecursionError/
# MemoryError) is the one parse failure that asks instead. The "same invariant" claim below is scoped to the
# hooks/enabledPlugins/env comparison itself, not this file's entire error
# handling.
#
# Scope: Write and Edit tools only. MultiEdit is out of scope. A
# Bash-mediated create or edit (`echo '{}' > .claude/settings.json`, `jq`/
# `sed -i` rewriting an existing one) bypasses this gate entirely -- accepted
# gap, not closed here; a Bash-argv parser for this file is out of
# proportion to this fix.
#
# #98, deferred-idea backlog filed from spec #75's migration (2026-08-24).
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found -- config-write-guard cannot run; allowing" >&2
  exit 0
fi

case $0 in */*) _gdir="${0%/*}" ;; *) _gdir=. ;; esac  # not $(dirname): saves a fork
_py="$_gdir/config-write-guard.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script config-write-guard.py missing or unreadable -- allowing (config-write-guard is ask-only, fails open)" >&2
  exit 0
fi

# Fast path (_silent_fastpath.sh): the python only speaks for a basename settings.json or
# settings.local.json (matched case-insensitively), so a payload without "settings" in any case
# and without "~" (expanduser could add text) exits silently.
if [ -r "$_gdir/_silent_fastpath.sh" ] && . "$_gdir/_silent_fastpath.sh"; then
  mh_gate_run "$_py" '[sS][eE][tT][tT][iI][nN][gG][sS]|~'
fi
python3 -S "$_py"
