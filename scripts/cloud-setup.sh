#!/usr/bin/env bash
# Setup script for Claude Code on the web: paste this file's contents into the cloud
# environment's "Setup script" box. Installs and enables mh (gates, skills, agents) and
# mattpocock-skills, plus trash-cli so the irrecoverable gate's "use trash-put" path works.
# Evidence: docs/research/mh-cloud-probe-2026-11-06/probe-results.md.
# The setup script must exit 0 within about 5 minutes; worst case is about 4.5 minutes:
# 4 x 35 + 20 + 45 + 30 s, plus 5 s kill grace per step.
set +e
# fallback: a failed step must not stop the environment from starting; each step logs to $LOG.
trap 'exit 0' EXIT
LOG=/tmp/mh-cloud-setup.log
export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
step() { local secs=$1; shift; echo "--- $*"; timeout -k 5 "$secs" "$@" </dev/null; echo "exit=$?"; }
{
  step 35 claude plugin marketplace add wasikarn/method-harness
  step 35 claude plugin install mh@wasikarn
  step 20 claude plugin enable mh@wasikarn   # mh ships defaultEnabled: false; mattpocock-skills installs enabled
  step 35 claude plugin marketplace add mattpocock/skills
  step 35 claude plugin install mattpocock-skills@mattpocock
  if ! command -v trash-put >/dev/null; then
    step 45 apt-get update -qq
    step 30 apt-get install -y -qq trash-cli
  fi
  echo "trash-put: $(command -v trash-put || echo MISSING)"
} >"$LOG" 2>&1
