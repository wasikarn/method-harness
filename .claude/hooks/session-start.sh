#!/usr/bin/env bash
# Project SessionStart hook: in Claude Code cloud sessions, wire core.hooksPath when a fresh clone
# lacks it, and install the gauntlet's tools: trash-cli
# (tests reset state with `trash`) and shfmt >= 3.5 (run-gauntlet.sh refuses to start without it;
# tests/scripts/test-pipefail-grep-q-lint.sh parses every shell file with it). Local machines are
# never touched (macOS: `brew install trash shfmt`). Never blocks a session: every failure is a
# stderr note and exit 0. apt and pip output go to stderr because SessionStart stdout is injected
# into the model's context.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

# shfmt_ok: shfmt on PATH and at least 3.5 (3.4, Ubuntu 22.04's apt package, lacks --to-json).
shfmt_ok() {
  local v maj min
  v=$(shfmt --version 2>/dev/null) || return 1
  v=${v#v}; maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  case "$maj$min" in *[!0-9]*|"") return 1 ;; esac
  [ "$maj" -gt 3 ] || { [ "$maj" -eq 3 ] && [ "$min" -ge 5 ]; }
}

note() { echo "session-start: $*" >&2; }

# A fresh cloud clone has no core.hooksPath, so its commits and pushes run zero gates (there is no
# CI). Wire the relative path CLAUDE.md requires; a value already set, even a broken one, is left
# for the operator (docs/reference/repo-gotchas.md "Git hooks").
proj=${CLAUDE_PROJECT_DIR:-}
if [ -n "$proj" ] && [ -d "$proj/git-hooks" ] && command -v git >/dev/null \
  && ! git -C "$proj" config --get core.hooksPath >/dev/null 2>&1; then
  if git -C "$proj" config core.hooksPath git-hooks </dev/null >&2; then
    note "set core.hooksPath to git-hooks (it was unset, so no git hook would run)"
  else
    note "git config core.hooksPath git-hooks failed; commits will run no hooks"
  fi
fi

need=()
command -v trash >/dev/null || need+=(trash-cli)
shfmt_ok || need+=(shfmt)
[ "${#need[@]}" -gt 0 ] || exit 0

sudo="" apt=1
if ! command -v apt-get >/dev/null; then
  note "no apt-get"; apt=0
elif [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null; then sudo="sudo -n"; else note "not root and no sudo"; apt=0; fi
fi
# `env` inside sudo: sudo's env_reset drops an exported DEBIAN_FRONTEND. stdin is the hook payload.
apt_get() { $sudo env DEBIAN_FRONTEND=noninteractive apt-get -q "$@" </dev/null >&2; }
if [ "$apt" = 1 ]; then
  # Try without `apt-get update` first: a container with fresh package lists skips the network round trip.
  apt_get install -y "${need[@]}" || { apt_get update && apt_get install -y "${need[@]}"; } \
    || note "apt-get install ${need[*]} failed"
fi

command -v trash >/dev/null \
  || note "no \`trash\` command (try: pip install trash-cli); the gauntlet's trash-dependent tests will fail"
if ! shfmt_ok; then
  # Ubuntu 22.04's apt shfmt is 3.4; the shfmt-py wheel ships a current release.
  if command -v pip >/dev/null; then
    pip install -q shfmt-py </dev/null >&2 || note "pip install shfmt-py failed"
    hash -r
  fi
  shfmt_ok || note "no shfmt >= 3.5 (try: pip install shfmt-py); run-gauntlet.sh refuses to start without it"
fi
exit 0
