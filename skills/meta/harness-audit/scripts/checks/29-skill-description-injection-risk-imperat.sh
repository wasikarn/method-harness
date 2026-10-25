#!/usr/bin/env bash
# 29. Skill description injection-risk + imperative-intensity scan.
# Checks that no SKILL.md / agents/*.md description: field contains prompt-injection patterns
# (override instructions, persona hijack, system-prompt escape attempts).
# Also emits INFO if description: > 500 chars (harder to audit, injection risk rises)
# and INFO if description: uses over-forceful imperatives (ALWAYS/CRITICAL/MUST/
# "if in doubt") — Opus 4.8+ over-triggers on older-model intensity; the doc fix is
# plain "Use when …" trigger phrasing (Anthropic prompting-Opus-4.8 guidance, 2026-06).
# Fires WARNING if injection patterns found; INFO for length/imperative — never CRIT
# (de-escalation is a judgment call: some ALWAYS/MUST triggers are load-bearing).
INJECTION_PATTERNS='(ignore (previous|prior|all) instruction|disregard (all|previous)|forget (everything|all)|you are now|act as if you|<system>|<\/system>|<user>|<\/user>|SYSTEM PROMPT|override your)'
IMPERATIVE_PATTERNS='\b(ALWAYS|CRITICAL|MUST|NEVER)\b|[Ii]f in doubt|[Dd]efault to using'
desc_inj_issues=0
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac
  case "$f" in */agents/*.md) skill_name="agent ${f##*/}" ;; *) _t=${f%/*}; skill_name=${_t##*/} ;; esac
  desc=$(fm_get "$f" "description" --block)
  [ -z "$desc" ] && continue
  if /usr/bin/grep -iEq "$INJECTION_PATTERNS" <<<"$desc"; then
    warn "skill '$skill_name' description: contains potential injection pattern — review manually"
    desc_inj_issues=$((desc_inj_issues + 1))
  fi
  if /usr/bin/grep -Eq "$IMPERATIVE_PATTERNS" <<<"$desc"; then
    info "skill '$skill_name' description: over-forceful imperative (ALWAYS/CRITICAL/MUST/NEVER/'if in doubt') — current models over-trigger on it; prefer 'Use when …'"
  fi
done
# No output on clean — crit/warn/info only when there's an issue (audit.sh convention)

