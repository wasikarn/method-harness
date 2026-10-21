#!/usr/bin/env bash
# 10. Duplicate tools in agent grants
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  tools=$(fm_get "$f" "tools" --block)
  if [ -n "$tools" ]; then
    dups=$(echo "$tools" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort | uniq -d)
    if [ -n "$dups" ]; then
      warn "agent '$name' duplicate tools: $dups"
    fi
  fi
done

