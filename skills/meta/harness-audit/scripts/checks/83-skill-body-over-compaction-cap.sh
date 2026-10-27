#!/usr/bin/env bash
# 83. SKILL.md over the post-compaction re-attach cap.
#
# After auto-compaction Claude Code re-attaches each invoked skill but keeps only its first
# 5,000 tokens (code.claude.com/docs/en/skills.md, Skill content lifecycle), so a long run that
# compacts silently loses a skill's closing steps. 18,000 bytes is ~5,000 tokens at ~3.6 bytes a
# token for English markdown: an estimate, not a tokenizer count. Fix by moving detail into
# references/ and keeping the steps that must hold near the top. WARN: a completeness risk.
for _f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md; do
  [ -f "$_f" ] || continue
  _b=$(wc -c <"$_f" | tr -d ' ')
  [ "$_b" -gt 18000 ] && warn "${_f#"$CLAUDE_DIR"/} is $_b bytes (> 18000, ~5,000 tokens): after compaction Claude Code keeps only its first ~5,000 tokens, so its last steps can drop"
done
unset _f _b
