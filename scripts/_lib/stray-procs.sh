#!/usr/bin/env bash
# stray-procs.sh — name the operator's own long-running CPU-heavy processes (GH #158). A stress run
# whose cleanup failed (`kill $(jobs -p)` under the Bash tool's zsh -c found no jobs) left 4 `yes`
# processes at 100% CPU for about 4 h on 2026-10-25; the load stayed ~6 and every push's timing rows
# failed until someone spotted them. This shortens detection to the next gauntlet run. Source it, then:
#   stray_procs_report
# It prints a warning to stderr listing your processes older than GAUNTLET_STRAY_MIN_SECS (1800) at or
# above GAUNTLET_STRAY_MIN_CPU percent (80), with the load average. It never kills anything (a
# process may belong to a peer session's live run; killing it is the operator's call), never returns
# non-zero, and stays silent when ps fails, so a `set -e` caller is never aborted. Detection is by
# behaviour, not by name: a long build at full CPU is named too, which is the point of a warning.
# The 30 min default skips a busy headless `claude` run (named at 13 min on the first live run); the
# strays this targets ran for hours.
# Bash 3.2.

_sp_num() {
  case "${1:-}" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}

# Your own processes as "pid etime %cpu command" (etime: [[dd-]hh:]mm:ss; macOS ps has no etimes).
_sp_ps() { ps -U "$(id -u)" -o pid=,etime=,%cpu=,command= 2>/dev/null; }

_sp_load() {
  uptime 2>/dev/null | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{print $1}'
}

stray_procs_report() {
  local min_secs min_cpu rows found
  min_secs=$(_sp_num "${GAUNTLET_STRAY_MIN_SECS:-}" 1800)
  min_cpu=$(_sp_num "${GAUNTLET_STRAY_MIN_CPU:-}" 80)
  rows=$(_sp_ps) || return 0
  found=$(printf '%s\n' "$rows" | awk -v ms="$min_secs" -v mc="$min_cpu" '
    NF >= 4 {
      e = $2; d = 0
      if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + t[i]
      s += d * 86400
      if (s < ms || $3 + 0 < mc) next
      cmd = $4; for (i = 5; i <= NF; i++) cmd = cmd " " $i
      printf "  pid %s  %s  %s%%  %s\n", $1, $2, $3, substr(cmd, 1, 120)
    }') || return 0
  [ -n "$found" ] || return 0
  {
    echo "gauntlet: warning: load $(_sp_load); these processes of yours have run ${min_secs}s+ at ${min_cpu}%+ CPU."
    echo "gauntlet: a leftover stress run fails the timing rows; check them before re-running (this never kills anything):"
    printf '%s\n' "$found"
  } >&2
  return 0
}
