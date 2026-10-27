#!/usr/bin/env bash
# 83. SKILL.md over the post-compaction re-attach cap.
#
# After auto-compaction Claude Code re-attaches each invoked skill but keeps only its first
# 5,000 tokens (code.claude.com/docs/en/skills.md, Skill content lifecycle), so a long run that
# compacts silently loses a skill's closing steps. 5,000 tokens is ~18,000 bytes at ~3.6 bytes a
# token for English markdown, an estimate rather than a tokenizer count (code- and path-heavy
# text runs nearer 3), so the limit is 16,000 bytes to leave headroom. Fix by moving detail into
# references/ and keeping the steps that must hold near the top. WARN: a completeness risk.
# Same file set and scaffold skip as check 28.
_cap=16000
for _f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/*/SKILL.md; do
  [ -f "$_f" ] || continue
  _d=${_f%/*}
  case "${_d##*/}" in _*) continue ;; esac
  _b=$(wc -c <"$_f" | tr -d ' ')
  [ "$_b" -gt "$_cap" ] && warn "${_f#"$CLAUDE_DIR"/} is $_b bytes (> $_cap; ~5,000 tokens is ~18,000): after compaction Claude Code keeps only its first ~5,000 tokens, so its last steps can drop"
done
unset _f _d _b _cap
