#!/usr/bin/env bash
# 82. Unknown top-level frontmatter key (skills, agents).
#
# Claude Code ignores a frontmatter field it doesn't recognize without reporting an error
# (code.claude.com/docs/en/skills.md Frontmatter reference; sub-agents.md says the same for
# agents), so a typo such as `disable-model-invocaton` silently turns a user-only skill
# model-invocable. Known sets: the skills.md and sub-agents.md frontmatter tables (fetched
# 2026-10-27), plus mh-native keys (skill-authoring-conventions.md; check 04's agent `bucket`).
# Nested keys under `metadata:` or `hooks:` are indented and not read; an unterminated block
# reports nothing (check 28 owns YAML validity). CRIT when the unknown key is a near-miss of a
# permission or invocation field (the silent-typo case); WARN otherwise, since vendor docs lag
# new fields. Same file set and scaffold skip as check 28.
_skill_keys=" name description when_to_use argument-hint arguments disable-model-invocation user-invocable allowed-tools disallowed-tools model effort context agent background hooks paths shell metadata license compatibility model_limitation disable-model-invocation-reason "
_agent_keys=" name description tools disallowedTools model permissionMode maxTurns autoCompactWindow skills mcpServers hooks memory background omitClaudeMd effort isolation color initialPrompt experimental bucket "
# CRLF-safe; trailing spaces on a `---` marker allowed; keys printed only once the block closes.
_fm_keys() { awk '{sub(/\r$/,"")} NR==1 && $0 !~ /^---[ \t]*$/ {exit} NR>1 && /^---[ \t]*$/ {for (i=1;i<=n;i++) print k[i]; exit} NR>1 && /^[A-Za-z_][A-Za-z0-9_-]*:/ {sub(/:.*/,""); k[++n]=$0}' "$1"; }
# Near-miss of a permission/invocation field: same letters after dropping case, '-' and '_', or
# one edit away (difflib ratio >= 0.85).
_near_safety() { python3 - "$1" <<'PY'
import difflib, sys
k = sys.argv[1].lower().replace('-', '').replace('_', '')
safety = ['disable-model-invocation', 'user-invocable', 'allowed-tools', 'disallowed-tools', 'tools', 'disallowedTools', 'permissionMode']
sys.exit(0 if any(difflib.SequenceMatcher(None, k, s.lower().replace('-', '').replace('_', '')).ratio() >= 0.85 for s in safety) else 1)
PY
}
for _f in "$CLAUDE_DIR/agents"/*.md "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/*/SKILL.md; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$CLAUDE_DIR"/}
  _d=${_f%/*}
  case "${_f##*/} ${_d##*/}" in _*|*" _"*) continue ;; esac
  case "$_rel" in agents/*) _known=$_agent_keys ;; *) _known=$_skill_keys ;; esac
  while IFS= read -r _k; do
    case "$_known" in *" $_k "*) continue ;; esac
    _near_safety "$_k" && _rc=0 || _rc=$?
    case $_rc in
      0) crit "$_rel: frontmatter key '$_k' is a near-miss of a permission/invocation field (misspelled, or valid only on the other file type); Claude Code ignores it silently" ;;
      1) warn "$_rel: frontmatter key '$_k' is not a documented Claude Code field or an mh-native key (Claude Code ignores it silently; a typo?)" ;;
      # Fail closed: a broken python3 must not downgrade a real near-miss to WARN.
      *) crit "$_rel: frontmatter key '$_k' is unknown and the near-miss check failed (python3 exit $_rc), so a misspelled permission field can't be ruled out" ;;
    esac
  done < <(_fm_keys "$_f")
done
unset _f _k _rc _rel _d _known _skill_keys _agent_keys
unset -f _fm_keys _near_safety
