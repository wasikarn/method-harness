#!/usr/bin/env bash
# 2. Symlink integrity — skills
#
# CI-safety (reproduced 2026-08-28 by an adversarial plan review: 0 CRIT
# locally vs 76 CRIT under an isolated $HOME simulating a fresh GitHub
# runner). This loop's per-component F1 CRIT depends on either a local
# ~/.claude symlink farm (dev-mode install) or the plugin cache
# ($PLUGIN_ACTIVE, set earlier in audit.sh) — a clean checkout with neither
# has genuinely no way to prove loadability, which is a different fact than
# "every skill is missing." Distinguish by whether $HOME/.claude/skills
# holds at least one symlink: if it does, this machine is using symlink-mode
# and a missing individual symlink is still a real, per-component gap
# (unchanged behavior below). If it does not, AND $PLUGIN_ACTIVE=0, neither
# delivery mechanism is configured here at all — downgrade to one aggregated
# WARN instead of one CRIT per skill, and skip the loop. The dir alone is not
# enough: a cloud session ships ~/.claude/skills holding its own plain dirs
# (session-start-hook, synced), which read as a farm with every link missing,
# 12 CRIT (cloud audit 2026-10-23, F6).
_farm=0
for _e in "$HOME/.claude/skills"/*; do
  [ -L "$_e" ] && { _farm=1; break; }
done
if [ "${PLUGIN_ACTIVE:-0}" -eq 0 ] && [ "$_farm" -eq 0 ]; then
  warn "no plugin cache and no ~/.claude/skills symlink farm present — skill loadability unverified in this environment (expected on a clean CI checkout; not a per-skill finding)"
else
for d in "$CLAUDE_DIR/skills"/*/ "$CLAUDE_DIR/skills"/*/*/; do
  [ -d "$d" ] || continue
  _t=${d%/}; name=${_t##*/}
  # Skip self during bootstrap; skip _-prefixed scaffolds (not deployed skills —
  # install.sh applies the same `_*` rule so the two never disagree). Skip
  # *-workspace dirs too — skill-creator eval workspaces, gitignored under
  # .gitignore's own "Session / skill workspaces" section, never deployed.
  [ "$name" = "harness-audit" ] && continue
  case "$name" in _*|*-workspace) continue ;; esac
  # A directory under skills/ with no SKILL.md was never an invocable skill;
  # nothing here could load, so "not loadable" would be a false positive.
  [ -f "$d/SKILL.md" ] || continue
  # Skip upstream-tracked skills (Matt Pocock + gstack + ECC + etc.) — locked
  # in ~/.agents/.skill-lock.json. Editing them drifts the content hash and
  # corrupts the install. They are intentionally NOT symlinked to dotfiles.
  # SSOT: ~/.agents/.skill-lock.json, record in memory `project_skill_lock_ssot`.
  for locked in "${LOCKED_SKILLS[@]:-}"; do
    [ "$name" = "$locked" ] && continue 2
  done
  if [ ! -L "$HOME/.claude/skills/$name" ] && ! is_plugin_delivered skills "$name"; then
    if new_vs_base "${d%/}/SKILL.md"; then
      info "skill '$name' is new vs ${NEW_VS_BASE:-base}; not in the plugin cache until a bumped version is merged and installed"
    else
      crit "skill '$name' not loadable by Claude Code (not in plugin cache and not symlinked)"
    fi
  fi
done
fi

