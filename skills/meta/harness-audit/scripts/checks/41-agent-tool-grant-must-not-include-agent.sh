#!/usr/bin/env bash
# 41. Agent tool-grant must not include Agent (Rule 13 one-level-deep dispatch). No agent in
# this fleet spawns further subagents — Rule 13 (docs/METHODOLOGY.md's "Orchestration shape" rule) is
# "a dispatched sub-agent must not re-dispatch." Check 09 already CRITs an agent missing
# tools: entirely (door 1: silent full-tool inheritance, including Agent). This check closes
# door 2: an explicit tools: grant that names Agent. WARN, not CRIT — a bad explicit grant is
# authored and reviewed before it ships (unlike door 1's silent inheritance), so it's
# recoverable by construction. Shares check 24's strip_tool_token() helper (in
# scripts/_lib/frontmatter-helpers.sh) so `Agent(...)` or JSON-array syntax still matches.
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  tv=$(fm_get "$f" "tools" --block)
  [ -n "$tv" ] || continue
  for tok in $(echo "$tv" | tr ',' ' '); do
    base="$(strip_tool_token "$tok")"
    if [ "$base" = "Agent" ]; then
      warn "agent '$name' tools: grants 'Agent' — breaks Rule 13's one-level-deep dispatch invariant (a subagent must not re-dispatch); no agent in this fleet should hold the Agent tool"
      break
    fi
  done
done
