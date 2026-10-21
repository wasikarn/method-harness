#!/usr/bin/env bash
# gate-canary.sh <gates-dir> [gate.sh...] — every gate in <gates-dir>/*.sh (or only the named
# gates) must ALLOW (rc 0) each benign payload below with no traceback on stderr. A NameError,
# an apostrophe inside an embedded python string, or a missing import in a gate
# blocks every Bash call machine-wide (2026-09-05 incident), so pre-commit runs
# this on the staged gates and tests/hooks/test-gate-canary.sh proves it fails
# on an injected slip. Gates run 4 at a time; each one's payloads run in order.
set -uo pipefail
if [ "${1:-}" = --one ]; then
  g="$2" fail=0
  for p in '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
           '{"tool_name":"Bash","agent_id":"canary","tool_input":{"command":"git status"}}' \
           '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts","old_string":"a","new_string":"b"}}' \
           '{"tool_name":"Write","tool_input":{"file_path":"src/app.ts","content":"x"}}' \
           '{"tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"in_progress"}}'; do
    err=$(printf '%s' "$p" | MH_GATE_NO_FASTPATH=1 bash "$g" 2>&1 >/dev/null); rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$err" | /usr/bin/grep -qiE 'Traceback|internal error|Error:'; then
      echo "gate canary failed: $g rc=$rc on $p" >&2
      printf '%s\n' "$err" | head -5 >&2
      fail=1
    fi
  done
  exit "$fail"
fi
dir="${1:?usage: gate-canary.sh <gates-dir> [gate.sh...]}"
shift
gates=()
if [ "$#" -gt 0 ]; then
  for g in "$@"; do gates+=("$dir/${g##*/}"); done
else
  for g in "$dir"/*.sh; do [ -f "$g" ] && gates+=("$g"); done
fi
[ "${#gates[@]}" -gt 0 ] || exit 0
for g in "${gates[@]}"; do
  [ -f "$g" ] || { echo "gate canary: no such gate: $g" >&2; exit 1; }
done
printf '%s\0' "${gates[@]}" | xargs -0 -n 1 -P 4 bash "$0" --one || exit 1
exit 0
