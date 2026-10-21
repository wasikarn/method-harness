#!/usr/bin/env bash
# Gate: ask before a model-invoked `Skill(codex:setup)` call carrying
# `--enable-review-gate`.
#
# The paired Codex plugin's own `/codex:setup --enable-review-gate` toggle
# turns on a Stop-time LLM-judgment review that can block a Claude Code
# session from ending -- exactly the shape the operating model keeps out of
# mh's deny/ask set (see GLOSSARY.md's "review gate" entry). Two of the eight
# `/codex:*` commands ship without `disable-model-invocation: true` --
# `codex:setup` and `codex:rescue` -- so nothing stops the model from calling
# either one itself. ADR-0001 records the split: this gate closes the
# `codex:setup` half (a one-line flag match, same shape as
# config-write-guard.sh); the `codex:rescue` half stays documented-only,
# since gating an Agent-tool dispatch by subagent_type has no precedent in
# this plugin.
#
# ASK, not DENY: the toggle is trivially reversible
# (`/codex:setup --disable-review-gate`), and a deliberate operator call to
# the same skill should not be hard-blocked -- same tier as
# config-write-guard.sh's settings-file edits.
#
# Scope: the Skill tool only. A Bash-mediated call into the codex plugin's
# own scripts (`node .../codex-companion.mjs setup --enable-review-gate`)
# bypasses this gate entirely -- accepted gap, matching
# config-write-guard.sh's own documented Bash-mediated-write gap.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found -- codex-setup-guard cannot run; allowing" >&2
  exit 0
fi

_py="$(dirname "$0")/codex-setup-guard.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script codex-setup-guard.py missing or unreadable -- allowing (codex-setup-guard is ask-only, fails open)" >&2
  exit 0
fi

python3 -S "$_py"  # -S: skip site import (stdlib-only gate)
