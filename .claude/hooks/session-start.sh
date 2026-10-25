#!/usr/bin/env bash
# Project SessionStart hook: install the gauntlet's tools in Claude Code cloud sessions: trash-cli
# (tests reset state with `trash`) and a shfmt whose syntax tree tests/_lib/pipe_into_grep_q.py reads
# (run-gauntlet.sh refuses to start without it; tests/scripts/test-pipefail-grep-q-lint.sh parses
# every shell file with it). Local machines are never touched (macOS: `brew install trash shfmt`).
# Never blocks a session: every failure is a stderr note and exit 0. apt and pip output go to stderr
# because SessionStart stdout is injected into the model's context.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

note() { echo "session-start: $*" >&2; }

here=${BASH_SOURCE[0]%/*}; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
scanner="$here/../../tests/_lib/pipe_into_grep_q.py"
# shfmt_ok [DIR]: the first shfmt on PATH (DIR put first, when given) passes the scanner's own
# canary: run with no files, the scanner only checks that it finds the race in `x | grep -q y`.
# A version check is not enough: Ubuntu 22.04's apt shfmt 3.4 lacks --to-json, and 24.04's apt
# 3.8.0 writes operators as numbers ("Op": 12 for `|`), so the scanner reads every file as clean.
shfmt_ok() { PATH="${1:+$1:}$PATH" python3 "$scanner" </dev/null >/dev/null 2>&1; }

# pip_shfmt_dir: the directory holding shfmt-py's shfmt, from pip's file list; empty if none.
pip_shfmt_dir() {
  local line loc="" f=""
  while IFS= read -r line; do
    case $line in
      "Location: "*) loc=${line#Location: } ;;
      "  shfmt" | "  "*/shfmt) f=${line#  } ;;
    esac
  done < <(pip show -f shfmt-py </dev/null 2>/dev/null)
  [ -n "$loc" ] && [ -n "$f" ] || return 0
  f="$loc/$f"
  (cd -P "${f%/*}" 2>/dev/null && pwd)
}

need_trash=0
command -v trash >/dev/null || need_trash=1
if [ "$need_trash" = 0 ] && shfmt_ok; then exit 0; fi

if [ "$need_trash" = 1 ]; then
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
    apt_get install -y trash-cli || { apt_get update && apt_get install -y trash-cli; } \
      || note "apt-get install trash-cli failed"
  fi
  command -v trash >/dev/null \
    || note "no \`trash\` command (try: pip install trash-cli); the gauntlet's trash-dependent tests will fail"
fi

if ! shfmt_ok; then
  # No apt for shfmt: no Ubuntu release's package passes (see shfmt_ok). The shfmt-py wheel ships
  # a current upstream build. PIP_BREAK_SYSTEM_PACKAGES: 24.04's pip refuses a system-wide install
  # otherwise (PEP 668); older pip ignores the variable, where a flag would be an error.
  dir=""
  if command -v pip >/dev/null; then
    dir=$(pip_shfmt_dir)
    # Installed by an earlier session but shadowed on PATH: skip pip, just put it first again below.
    if [ -z "$dir" ] || ! shfmt_ok "$dir"; then
      PIP_BREAK_SYSTEM_PACKAGES=1 pip install -q shfmt-py </dev/null >&2 || note "pip install shfmt-py failed"
      hash -r
      dir=$(pip_shfmt_dir)
    fi
  fi
  if shfmt_ok; then
    :
  elif [ -n "$dir" ] && shfmt_ok "$dir"; then
    shadow=$(command -v shfmt) || shadow="nothing (pip's directory is not on PATH)"
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      printf 'export PATH=%q:"$PATH"\n' "$dir" >> "$CLAUDE_ENV_FILE"
      note "pip's $dir/shfmt is usable but PATH finds $shadow first; put $dir first on PATH for this session"
    else
      note "pip's $dir/shfmt is usable but PATH finds $shadow first; put $dir first on PATH or the gauntlet refuses to start"
    fi
  else
    why=$(python3 "$scanner" 2>&1 </dev/null)
    note "no usable shfmt (try: pip install shfmt-py); run-gauntlet.sh refuses to start without it: ${why:-no reason given}"
  fi
fi
exit 0
