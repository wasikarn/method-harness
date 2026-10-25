#!/usr/bin/env bash
# 81. Reference file over 100 lines has a table of contents (skills/).
#
# Anthropic's skill best practices: a file reached from another referenced file may be
# previewed with `head -100`, so a reference file longer than 100 lines needs a "Contents"
# heading near the top (outside a code fence) to show its full scope. WARN: a completeness risk, not a safety class.
while IFS= read -r _f; do
  [ "$(grep -c '' "$_f")" -gt 100 ] || continue
  grep -qiE '^#{1,3} (table of )?contents[[:space:]]*$' <<<"$(head -30 "$_f" | awk '/^(```|~~~)/{f=!f;next} !f')" || warn "reference file ${_f#"$CLAUDE_DIR"/} is over 100 lines with no '## Contents' heading in its first 30 lines (a partial head -100 read would miss most of it)"
done < <(find "$CLAUDE_DIR/skills" -name '*.md' ! -name SKILL.md 2>/dev/null)
unset _f
