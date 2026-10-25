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
# `env` inside sudo: sudo's env_reset drops an exported DEBIAN_FRONTEND. stdin is the hook payload.
apt_get() { $sudo env DEBIAN_FRONTEND=noninteractive apt-get -q "$@" </dev/null >&2; }
# Try without `apt-get update` first: a container with fresh package lists skips the network round trip.
apt_get install -y trash-cli || { apt_get update && apt_get install -y trash-cli; } \
  || warn "apt-get install trash-cli failed"
command -v trash >/dev/null \
  || warn "trash-cli installed without a \`trash\` command (try: pip install trash-cli)"
exit 0
