#!/usr/bin/env bash
# 9. Tool-grant scoping (agents must have explicit tools:)
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  if ! grep -q '^tools:' "$f"; then
    crit "agent '$name' missing tools: grant (inherits all)"
  fi
done

