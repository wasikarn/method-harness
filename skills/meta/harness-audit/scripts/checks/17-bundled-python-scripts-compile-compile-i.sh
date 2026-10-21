#!/usr/bin/env bash
# 17. Bundled Python scripts compile (compile() is in-memory — writes no .pyc)
# One python3 for every file (was one spawn per file); it prints each failing path in find order.
# If python3 itself cannot start, every file is reported, as the per-file form did.
_py17=()
while IFS= read -r f; do _py17+=("$f"); done < <(find "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks" -name '*.py' -not -path '*__pycache__*' 2>/dev/null || true)
if [ "${#_py17[@]}" -gt 0 ]; then
  if _bad17=$(python3 - "${_py17[@]}" <<'PY' 2>/dev/null
import sys
for p in sys.argv[1:]:
    try:
        compile(open(p).read(), p, 'exec')
    except BaseException:
        print(p)
PY
  ); then :; else _bad17=$(printf '%s\n' "${_py17[@]}"); fi
  while IFS= read -r f; do
    [ -n "$f" ] && crit "bundled script '${f#$CLAUDE_DIR/}' has a Python syntax error"
  done <<< "$_bad17"
fi
unset _py17 _bad17

