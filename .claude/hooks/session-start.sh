#!/usr/bin/env bash
# Project SessionStart hook: install trash-cli in Claude Code cloud sessions, so the gauntlet's
# trash-dependent tests pass there. Local machines are never touched (macOS: `brew install trash`).
# Never blocks a session: every failure is one stderr warning and exit 0. apt output goes to
# stderr because SessionStart stdout is injected into the model's context.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
command -v trash >/dev/null && exit 0

warn() { echo "session-start: $*; the gauntlet's trash-dependent tests will fail" >&2; exit 0; }

command -v apt-get >/dev/null || warn "no trash and no apt-get"
sudo=""
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null || warn "no trash, not root, and no sudo"
  sudo="sudo -n"
fi
export DEBIAN_FRONTEND=noninteractive
# Try without `apt-get update` first: a container with fresh package lists skips the network round trip.
$sudo apt-get install -y -q trash-cli >&2 \
  || { $sudo apt-get update -q >&2 && $sudo apt-get install -y -q trash-cli >&2; } \
  || warn "apt-get install trash-cli failed"
command -v trash >/dev/null \
  || warn "trash-cli installed without a \`trash\` command (try: pip install trash-cli)"
exit 0
