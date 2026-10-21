#!/usr/bin/env bash
# 42. Reference-file frontmatter leak (skills/).
#
# A skill's `references/` files are read only by explicit path from SKILL.md.
# Confirmed live (2026-07-20, `claude -p --debug-file`): any .md under a skill
# dir carrying a `description:` in frontmatter loads as its OWN skill, whatever
# the author intended. WARN: a namespace/token-budget leak, not a safety class.
shopt -s nullglob
_leak_candidates=("$CLAUDE_DIR"/skills/*/references/*.md "$CLAUDE_DIR"/skills/*/*/references/*.md)
shopt -u nullglob
for _f in "${_leak_candidates[@]}"; do
  [ -f "$_f" ] || continue
  case "${_f##*/}" in SKILL.md) continue ;; esac
  grep -q '^---' "$_f" || continue
  if [ -n "$(fm_get "$_f" "description" --block)" ]; then
    warn "reference file ${_f#"$CLAUDE_DIR"/} carries frontmatter with a description: — Claude Code loads it as an independent command/skill, not inert supporting material (strip the frontmatter, matching skills/workflow/ideate/references/frames.md's shape, or move the file outside skills/)"
  fi
done
unset _f _leak_candidates
