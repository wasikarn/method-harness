#!/usr/bin/env bash
# Sensor: before a Codex CLI Bash command runs, warn (additionalContext) if
# codex-quota-sensor.sh recently recorded a usage-limit/rate-limit failure.
# Advises; denies only while a recorded reset time is still ahead (MH_CODEX_QUOTA_DENY=0 turns
# the deny off). Always exits 0.
# See codex-quota-advisory.py for the gap this closes.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:sensor] python3 not found — codex-quota-advisory cannot run; allowing (install python3 to restore Codex quota tracking)" >&2
  exit 0
fi

# ${0%/*}, not $(dirname), saves a fork on every call.
case $0 in */*) _py="${0%/*}/codex-quota-advisory.py" ;; *) _py=codex-quota-advisory.py ;; esac
if [ ! -r "$_py" ]; then
  echo "[mh:sensor] internal error: sibling script codex-quota-advisory.py missing or unreadable — allowing" >&2
  exit 0
fi

# Fast path (GH #326): python acts only when its state file exists (argv path,
# else MH_CODEX_QUOTA_STATE_FILE, else the default; empty counts as unset, as
# in default_state_path). No file means python opens nothing and stays silent.
# HOME unset: python reads the passwd home instead, so leave that case to it.
if [ -n "${HOME+set}" ] && [ ! -e "${1-${MH_CODEX_QUOTA_STATE_FILE:-$HOME/.cache/mh/codex-quota-state.json}}" ]; then
  exit 0
fi

python3 -S "$_py" "$@"
exit 0
