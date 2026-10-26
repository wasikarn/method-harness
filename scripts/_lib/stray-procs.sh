#!/usr/bin/env bash
# stray-procs.sh — name the operator's own long-running CPU-heavy process groups (GH #158). Two
# stress runs typed into the Bash tool's zsh left their workers behind: 289 processes at load ~248
# (2026-10-05, `wait $pids` does not word-split in zsh) and 4 `yes` at 100% CPU for ~4 h
# (2026-10-25, `kill $(jobs -p)` found no jobs under `zsh -c`). Every push's timing rows failed
# until someone spotted them. This shortens detection to the next gauntlet run. Source it, then:
#   stray_procs_report
# Your processes older than GAUNTLET_STRAY_MIN_SECS (1800) are grouped by command name, and a group
# whose %CPU sums to GAUNTLET_STRAY_MIN_CPU (80) or more is listed on stderr with the load average.
# Summing per group catches both shapes: one process at full CPU, and a flood of many processes at a
# few percent each; many idle copies (macOS keeps 40+ SetStoreUpdateService) sum to ~0 and stay quiet.
# It never kills anything (a process may belong to a peer session's live run; killing it is the
# operator's call) and never returns non-zero, so a `set -e` caller is never aborted; when ps fails it
# says so in one line and skips. Detection is by behaviour, not by name: a long build at full CPU is
# named too, which is the point of a warning. The 30 min default skips a busy headless `claude` run
# (named at 13 min on the first live run); the strays this targets ran for hours. Bash 3.2.

# A numeric env setting, or its default when unset or not a whole number: a typo such as "1h" must
# not reach awk as a threshold (same rule as _gl_num in gauntlet-lock.sh).
_sp_num() {
  case "${1:-}" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}

# Your own processes as "pid etime %cpu command" (etime: [[dd-]hh:]mm:ss; macOS ps has no etimes).
_sp_ps() { ps -U "$(id -u)" -o pid=,etime=,%cpu=,command= 2>/dev/null; }

_sp_load() {
  uptime 2>/dev/null | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{print $1}'
}

stray_procs_report() {
  local min_secs min_cpu rows found load
  min_secs=$(_sp_num "${GAUNTLET_STRAY_MIN_SECS:-}" 1800)
  min_cpu=$(_sp_num "${GAUNTLET_STRAY_MIN_CPU:-}" 80)
  rows=$(_sp_ps) || { echo "gauntlet: stray-process check skipped (ps failed)" >&2; return 0; }
  found=$(printf '%s\n' "$rows" | awk -v ms="$min_secs" -v mc="$min_cpu" '
    NF >= 4 {
      e = $2; d = 0
      if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, t, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + t[i]
      s += d * 86400
      if (s < ms) next
      k = $4; sub(".*/", "", k)
      if (!(k in cnt)) { keys[++nk] = k; cmd[k] = $4; for (i = 5; i <= NF; i++) cmd[k] = cmd[k] " " $i }
      cnt[k]++; sum[k] += $3
      if (cnt[k] <= 8) pids[k] = pids[k] " " $1; else if (cnt[k] == 9) pids[k] = pids[k] " ..."
      if (s > old[k]) { old[k] = s; oldest[k] = $2 }
    }
    END {
      for (j = 1; j <= nk; j++) {
        k = keys[j]
        if (sum[k] < mc) continue
        printf "  %s: %d process%s at %.1f%% CPU, oldest %s, pids%s; %s\n", k, cnt[k], (cnt[k] == 1 ? "" : "es"), sum[k], oldest[k], pids[k], substr(cmd[k], 1, 100)
      }
    }') || { echo "gauntlet: stray-process check skipped (awk failed)" >&2; return 0; }
  [ -n "$found" ] || return 0
  load=$(_sp_load) || load=""
  {
    echo "gauntlet: warning: load ${load:-unknown}; these process groups of yours have run ${min_secs}s+ at ${min_cpu}%+ CPU in total."
    echo "gauntlet: a leftover stress run fails the timing rows; check them before re-running (this never kills anything):"
    printf '%s\n' "$found"
  } >&2
  return 0
}
