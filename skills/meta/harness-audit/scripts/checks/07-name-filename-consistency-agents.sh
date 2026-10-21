#!/usr/bin/env bash
# 7. Name/filename consistency — agents
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  file=${f##*/}; file=${file%.md}
  name=$(fm_get "$f" "name" --block)
  if [ -n "$name" ] && [ "$file" != "$name" ]; then
    crit "agent file='$file' name='$name' mismatch"
  fi
done

