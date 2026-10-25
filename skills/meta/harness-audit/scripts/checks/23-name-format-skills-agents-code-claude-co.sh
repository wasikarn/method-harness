#!/usr/bin/env bash
# 23. Name format — skills + agents. code.claude.com/docs/en/skills + /sub-agents:
# name = lowercase letters, digits, hyphens only; max 64 chars. A bad name breaks
# discovery/namespacing. Scaffolds (_*) ship placeholder names — skipped. The char
# class below already rejects a bare `:` (reserved for plugin-scoped agent IDs like
# `my-plugin:reviewer`), so that part of sub-agents.md's name rule needs no separate
# check — verified 2026-08-29 against a round-2 audit claim that overlooked this loop
# already covering agents/*.md.
# Reserved-word ban (platform.claude.com/docs/en/agents-and-tools/agent-skills/
# best-practices.md, verified 2026-08-29): name must not contain "anthropic" or
# "claude". No separate XML-tag check is needed here — the char-class regex below
# already excludes XML tags from name; that ban is real for description too, just
# not checked (check 20's own char-limit is a separate, deliberately unresolved gap).
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac
  label=${f##*/}; label=${label%.md}; [ "$label" = "SKILL" ] && { _t=${f%/*}; label=${_t##*/}; }
  nm=$(fm_get "$f" "name" --block)
  [ -n "$nm" ] || continue
  if ! grep -qE '^[a-z0-9-]{1,64}$' <<<"$nm"; then
    crit "'$label' name='$nm' violates format (lowercase/digits/hyphens, <=64 chars)"
  fi
  if grep -qE 'anthropic|claude' <<<"$nm"; then
    crit "'$label' name='$nm' contains a reserved word (anthropic/claude — official Agent Skills spec)"
  fi
  # sub-agents.md-only rule: an agent name can't start with a hyphen. The shared
  # char-class regex above allows one (`-` is a valid class member anywhere in the
  # string), so this needs its own check, scoped to agents/*.md only — the skills
  # spec never states this restriction for skill names.
  case "$f" in
    */agents/*)
      case "$nm" in
        -*) crit "'$label' name='$nm' starts with a hyphen (not allowed for agent names)" ;;
      esac
      ;;
  esac
done

