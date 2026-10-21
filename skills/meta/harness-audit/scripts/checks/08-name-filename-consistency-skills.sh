#!/usr/bin/env bash
# 8. Name/filename consistency — skills
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md; do
  [ -f "$f" ] || continue
  _t=${f%/*}; dir=${_t##*/}
  # _-prefixed scaffolds ship placeholder names (e.g. your-skill-name); not deployed
  case "$dir" in _*) continue ;; esac
  name=$(fm_get "$f" "name" --block)
  if [ -n "$name" ] && [ "$dir" != "$name" ]; then
    crit "skill dir='$dir' name='$name' mismatch"
  fi
done

