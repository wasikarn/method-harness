#!/usr/bin/env bash
# 3. Agent loadability (plugin cache or ~/.claude/agents symlink). The hooks
# loop that used to live here was a strict subset of check 11 and was dropped
# 2026-09-05 (round-3 review).
# 3b. Symlink integrity — agents.
# Regression guard: 14 agents (and, historically, at least one command — see
# CLAUDE.md) were committed to the repo but never symlinked into ~/.claude/,
# so Claude Code could not load them. No check caught it because symlink
# integrity covered only skills and hooks. (The commands/ loop that used to
# live here was dropped 2026-08-25, #112 — commands/ retired as a surface
# type entirely, every command converted to a skill.)
# CI-safety: same guard shape as check 02/the hooks loop above, a farm needs one symlink.
_farm=0
for _e in "$HOME/.claude/agents"/*; do
  [ -L "$_e" ] && { _farm=1; break; }
done
if [ "${PLUGIN_ACTIVE:-0}" -eq 0 ] && [ "$_farm" -eq 0 ]; then
  warn "no plugin cache and no ~/.claude/agents symlink farm present — agent loadability unverified in this environment (expected on a clean CI checkout; not a per-agent finding)"
else
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}
  if [ ! -L "$HOME/.claude/agents/$name" ] && ! is_plugin_delivered agents "${name%.md}"; then
    if new_vs_base "$f"; then
      info "agent '$name' is new vs ${NEW_VS_BASE:-base}; not in the plugin cache until a bumped version is merged and installed"
    else
      crit "agent '$name' not loadable by Claude Code (not in plugin cache and not symlinked)"
    fi
  fi
done
fi
