#!/usr/bin/env bash
# Setup script for Claude Code on the web: paste this file's contents into the cloud
# environment's "Setup script" box. Installs and enables mh (gates, skills, agents), then
# trash-cli (so the irrecoverable gate offers "use trash instead"), then mattpocock-skills.
# Evidence: docs/research/mh-cloud-probe-2026-11-06/probe-results.md.
# The setup script must exit 0 within about 5 minutes: each step gets at most its own cap and
# what is left of a 270 s budget, so a slow early step skips later ones (mh comes first).
# Later sessions reuse a snapshot of this script's result; it reruns only when the script or the
# allowed hosts change, or after about 7 days (cloud-environments docs), so cloud mh can lag
# develop by that long. To pick up a new mh (a gate fix) now, edit this line and save: v1
set +e
# fallback: a failed step must not stop the environment from starting; each step logs to $LOG.
trap 'exit 0' EXIT
LOG=/tmp/mh-cloud-setup.log
BUDGET=270
export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
step() {
  local cap=$1 left=$((BUDGET - SECONDS)); shift
  echo "--- $* (t=${SECONDS}s)"
  if [ "$left" -lt 5 ]; then echo "SKIPPED: setup time budget spent"; return 124; fi
  [ "$cap" -gt "$left" ] && cap=$left
  if command -v timeout >/dev/null; then timeout -k 5 "$cap" "$@" </dev/null; else "$@" </dev/null; fi
  local rc=$?; echo "exit=$rc (124 or 137 = timed out)"; return "$rc"
}
{
  command -v timeout >/dev/null || echo "timeout: MISSING, steps run without a time limit"
  step 60 claude plugin marketplace add wasikarn/method-harness
  step 60 claude plugin install mh@wasikarn
  step 20 claude plugin enable mh@wasikarn   # mh ships defaultEnabled: false
  # trash-cli, as in .claude/hooks/session-start.sh: root or sudo -n, noninteractive, install before update.
  if ! command -v trash >/dev/null && command -v apt-get >/dev/null; then
    sudo=""
    [ "$(id -u)" = 0 ] || sudo="sudo -n"
    # shellcheck disable=SC2086 # $sudo is empty or "sudo -n": word splitting intended.
    apt_get() { step "$1" $sudo env DEBIAN_FRONTEND=noninteractive apt-get -q "${@:2}"; }
    apt_get 30 install -y trash-cli || { apt_get 45 update && apt_get 30 install -y trash-cli; }
  fi
  echo "trash: $(command -v trash || echo MISSING)"
  step 60 claude plugin marketplace add mattpocock/skills
  step 60 claude plugin install mattpocock-skills@mattpocock   # installs enabled
  echo "done at t=${SECONDS}s"
} >"$LOG" 2>&1
