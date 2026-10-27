#!/usr/bin/env bash
# 82. Unknown top-level frontmatter key (skills, agents).
#
# Claude Code ignores a frontmatter field it doesn't recognize "without reporting an error"
# (code.claude.com/docs/en/skills.md, Frontmatter reference), so a typo such as
# `disable-model-invocaton` silently turns a user-only skill model-invocable. Known sets: the
# skills.md and sub-agents.md frontmatter tables (fetched 2026-10-27), plus mh-native keys
# (skill-authoring-conventions.md; check 04's agent `bucket`). Nested keys under `metadata:` or
# `hooks:` are indented and not read. WARN, not CRIT: vendor docs lag new fields.
_skill_keys=" name description when_to_use argument-hint arguments disable-model-invocation user-invocable allowed-tools disallowed-tools model effort context agent background hooks paths shell metadata license compatibility model_limitation disable-model-invocation-reason "
_agent_keys=" name description tools disallowedTools model permissionMode maxTurns autoCompactWindow skills mcpServers hooks memory background omitClaudeMd effort isolation color initialPrompt experimental bucket "
_fm_keys() { awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 && /^[A-Za-z_][A-Za-z0-9_-]*:/ {sub(/:.*/,""); print}' "$1"; }
for _f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$_f" ] || continue
  case "$_f" in */skills/_*) continue ;; */agents/*) _known=$_agent_keys ;; *) _known=$_skill_keys ;; esac
  while IFS= read -r _k; do
    case "$_known" in *" $_k "*) ;; *) warn "${_f#"$CLAUDE_DIR"/}: frontmatter key '$_k' is not a documented Claude Code field or an mh-native key (Claude Code ignores it silently; a typo?)" ;; esac
  done < <(_fm_keys "$_f")
done
unset _f _k _known _skill_keys _agent_keys
unset -f _fm_keys
