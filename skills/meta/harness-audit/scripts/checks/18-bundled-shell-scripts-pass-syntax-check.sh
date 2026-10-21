#!/usr/bin/env bash
# 18. Bundled shell scripts pass syntax check
# hooks/ added 2026-09-01 (deep-audit finding) -- this check previously scanned
# only skills/, leaving the entire hooks/ tree (gates, advisory, session, stop)
# invisible to the harness's own self-audit. Commit/push-time coverage already
# exists for hooks/*.sh (git-hooks/pre-commit, scripts/run-gauntlet.sh both run
# bash -n + shellcheck), but that only fires at commit/push -- this check is the
# one that can be run standalone, any time, mid-session, before a broken gate
# script is committed at all.
# The `bash -n` runs go 8-wide through xargs (was serial, ~0.45s); findings print in find order.
# Each worker prints "ok<TAB>path" on a clean parse, so a file whose worker never ran is reported too.
_sh18=()
while IFS= read -r f; do _sh18+=("$f"); done < <({ find "$CLAUDE_DIR/skills" -name '*.sh' 2>/dev/null; find "$CLAUDE_DIR/hooks" -name '*.sh' 2>/dev/null; } || true)
if [ "${#_sh18[@]}" -gt 0 ]; then
  declare -A _ok18=()
  while IFS=$'\t' read -r _st _p; do
    [ "$_st" = ok ] && _ok18["$_p"]=1
  done < <(printf '%s\0' "${_sh18[@]}" \
    | xargs -0 -n 8 -P 8 bash -c 'for p; do bash -n "$p" 2>/dev/null && printf "ok\t%s\n" "$p"; done; :' _ 2>/dev/null || true)
  for f in "${_sh18[@]}"; do
    [ -n "${_ok18[$f]:-}" ] || crit "bundled script '${f#$CLAUDE_DIR/}' has a shell syntax error"
  done
  unset _ok18
fi
unset _sh18 _st _p

