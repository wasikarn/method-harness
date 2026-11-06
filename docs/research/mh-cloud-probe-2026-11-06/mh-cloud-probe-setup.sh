#!/usr/bin/env bash
# Probe: can a cloud setup script install the mh plugin? Paste into the
# environment's "Setup script" box. Read the result with the prompt in
# mh-cloud-probe-prompt.md. It records facts only and changes nothing else.
# The setup script must exit 0 and finish in about 5 minutes (cloud-environments docs);
# worst case here is about 4 minutes: 30 s + 15 s + 3 x 65 s.
set +e
# fallback: a probe must never block the environment from starting; every error is in $LOG.
trap 'exit 0' EXIT
LOG=/tmp/mh-probe.log
# run SECS CMD...: no stdin, SIGTERM at SECS, SIGKILL 5 s later. Without coreutils `timeout`,
# a bash watchdog SIGKILLs at SECS+5 (shortcut: kills the CLI only, not its children; Ubuntu has timeout).
run() {
  local secs=$1; shift
  if command -v timeout >/dev/null; then timeout -k 5 "$secs" "$@" </dev/null; return; fi
  echo "note: no timeout binary, using a bash watchdog"
  "$@" </dev/null & local pid=$!
  ( sleep "$((secs + 5))"; kill -9 "$pid" ) >/dev/null 2>&1 & local dog=$!
  # fallback: the watchdog's kill fails harmlessly when the command already finished.
  wait "$pid"; local rc=$?
  kill "$dog" >/dev/null 2>&1
  return "$rc"
}
timed_out() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }
{
  echo "date: $(date -u +%FT%TZ)"
  echo "user: $(id -un)  HOME=$HOME  CLAUDE_CODE_REMOTE=${CLAUDE_CODE_REMOTE:-unset}"
  echo "claude: $(command -v claude || echo MISSING)"
  command -v claude >/dev/null && run 25 claude --version
  echo "python3: $(command -v python3 || echo MISSING)  timeout: $(command -v timeout || echo MISSING)"
  echo "jq: $(command -v jq || echo MISSING)  node: $(command -v node || echo MISSING)"
  echo "github reachable:"
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://github.com/wasikarn/method-harness || echo "curl failed"

  export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
  echo "--- marketplace add"
  run 60 claude plugin marketplace add wasikarn/method-harness; rc=$?
  echo "exit=$rc (124 or 137 = timed out)"
  if timed_out "$rc"; then
    echo "--- install and list SKIPPED: marketplace add timed out (same network path)"
  else
    echo "--- install"
    run 60 claude plugin install mh@wasikarn; rc=$?
    echo "exit=$rc (124 or 137 = timed out)"
    echo "--- list"
    run 60 claude plugin list
    echo "exit=$?"
  fi
} >"$LOG" 2>&1
