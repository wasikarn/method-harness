#!/usr/bin/env bash
# gauntlet-progress.sh: live progress for scripts/run-gauntlet.sh (GH #814), on the main process's stderr only.
# A step is one non-test layer (validate, lint, audit) or one test file. Layers and the test-layer jobs append one
# event line each to $prog ("S <name>" at start, "E <rc> <secs> <name>" at end: one write, O_APPEND, well under
# PIPE_BUF); progress_watch, in the foreground of the main process before report(), prints them. Plain lines only,
# each starting "gauntlet: " (never failing:, failed-at:, PASS, FAIL or SKIP, which callers parse), no \r, no ANSI.
# Bash 3.2: no mapfile, no associative arrays, no EPOCHREALTIME, no wait -n.
# Agreed by the issue's agent team (design, analysis, discussion); the record is in the PR.

prog_beat=30  # seconds without a progress line before a heartbeat names what is still running; tests set it lower

# progress_on: whether progress prints. prog_mode holds GAUNTLET_PROGRESS as run-gauntlet.sh read it: 1 is on, 0 is
# off, anything else (unset) is on only when stderr is a terminal. gauntlet_full defaults it to 1 for its callers.
progress_on() {
  case "${prog_mode:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
    *) [ -t 2 ] ;;
  esac
}

# progress_total <level> <shard> <ntests>: the steps this run has, known before any starts.
progress_total() {
  case "$1" in
    low) echo 1 ;;
    medium) echo $((3 + $3)) ;;
    *) if [ -z "$2" ] || [ "${2%/*}" -eq 1 ]; then echo $((2 + $3)); else echo "$3"; fi ;;
  esac
}

# progress_event <words...>: append one event line; never fails the caller.
progress_event() { printf '%s\n' "$*" >>"${prog:-/dev/null}" 2>/dev/null || true; }

# progress_layer <name> <cmd...>: run one non-test layer as one step, its output to $LOG/<name>, its code returned.
progress_layer() {
  local name=$1 s=$SECONDS rc
  shift
  progress_event S "$name"
  "$@" >"$LOG/$name" 2>&1
  rc=$?
  progress_event E "$rc" "$((SECONDS - s))" "$name"
  return "$rc"
}

_progress_dur() {
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

# progress_watch <total> <pid...>: print a header, then a line per finished step, and a heartbeat after prog_beat
# quiet seconds, until no pid is alive or every step has finished; then the "finished" line. It runs in the
# foreground, so it cannot outlive the script (a background child would hold merge-pr's $(... | tee) open), and every
# line it prints comes before report()'s, so the last line is still the failing: list (GH #387). Empty pids are skipped.
progress_watch() {
  local total=$1 seen=0 n done=0 last=$SECONDS t0=$SECONDS alive p kind a b c running="" now pct line
  shift
  printf 'gauntlet: %d steps\n' "$total" >&2
  while :; do
    alive=0
    for p in "$@"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1; done
    n=$(wc -l <"$prog" 2>/dev/null | tr -d ' ')
    n=${n:-0}
    if [ "$n" -gt "$seen" ]; then
      while read -r kind a b c; do
        case "$kind" in
          S) running="$running$a $SECONDS"$'\n' ;;
          E)
            done=$((done + 1))
            [ "$done" -le "$total" ] || total=$done
            running=$(printf '%s' "$running" | awk -v n="$c" 'NF && $1 != n { print }')
            [ -z "$running" ] || running="$running"$'\n'
            if [ "$a" = 0 ]; then line="PASS  $c ($(_progress_dur "$b"))"; else line="FAIL  $c ($(_progress_dur "$b"), rc $a)"; fi
            printf 'gauntlet: [%*d/%d %3d%%] %s\n' ${#total} "$done" "$total" $((done * 100 / total)) "$line" >&2
            last=$SECONDS
            ;;
        esac
      done < <(sed -n "$((seen + 1)),${n}p" "$prog")
      seen=$n
    fi
    [ "$alive" = 1 ] && [ "$done" -lt "$total" ] || break  # done >= total also stops it if a pid lingers
    now=$SECONDS
    if [ $((now - last)) -ge "$prog_beat" ]; then
      pct=0
      [ "$total" -eq 0 ] || pct=$((done * 100 / total))
      printf 'gauntlet: [%*d/%d %3d%%] running %s (%s elapsed)\n' ${#total} "$done" "$total" "$pct" \
        "$(printf '%s' "$running" | awk -v now="$now" 'NF { d = now - $2; printf "%s%s %s", sep, $1, (d >= 60 ? sprintf("%dm%02ds", d / 60, d % 60) : d "s"); sep = ", " }')" \
        "$(_progress_dur $((now - t0)))" >&2
      last=$now
    fi
    sleep 1
  done
  printf 'gauntlet: %d/%d steps finished in %s\n' "$done" "$total" "$(_progress_dur $((SECONDS - t0)))" >&2
}
