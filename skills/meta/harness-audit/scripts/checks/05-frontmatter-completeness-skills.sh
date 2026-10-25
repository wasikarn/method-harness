#!/usr/bin/env bash
# 5. Frontmatter completeness — skills
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac  # skip _-prefixed scaffolds (e.g. _template), per the _* convention
  _t=${f%/*}; name=${_t##*/}
  if ! grep -q '^---' "$f"; then
    crit "skill '$name' missing frontmatter"
  fi
  if [ -z "$(fm_get "$f" "name" --block)" ]; then
    crit "skill '$name' missing name: in frontmatter"
  fi
  if [ -z "$(fm_get "$f" "description" --block)" ]; then
    crit "skill '$name' missing description: in frontmatter"
  fi
  # Bucket check, path-derived (skills/<bucket>/<name>/SKILL.md). A flat skill
  # still loads via the default 1-level scan: WARN. A skill under an
  # unrecognized bucket dir is outside plugin.json's globs: CRIT.
  case "$f" in
    "$CLAUDE_DIR"/skills/*/*/SKILL.md)
      _t=${f%/*/*}; _bucket=${_t##*/}
      case "$_bucket" in
        meta|review|workflow|design) : ;;
        *) crit "skill '$name' is under unrecognized bucket dir '$_bucket' — plugin.json only covers meta/review and the listed workflow/design skills, so this skill is not discoverable" ;;
      esac
      ;;
    *) warn "skill '$name' is not under a bucket dir (flat skills/$name/SKILL.md) — outside the bucket convention (still loads via the default scan)" ;;
  esac
  # "Daisy" placeholder — exclude audit skill which documents this check
  if [ "$name" != "harness-audit" ] && grep -qi 'Daisy\|\\bdaisy\\b' "$f"; then
    warn "skill '$name' contains upstream 'Daisy' placeholder"
  fi
  # Trigger pattern (verb + scenario). Name-only skills (description ≤ 20
  # chars) carry no routing text; skip routing checks. Also excluded:
  # `disable-model-invocation: true` skills — a gated skill's description is
  # never read for auto-triggering at all (confirmed 2026-08-30: "removes the
  # skill from Claude's context entirely", code.claude.com/docs/en/skills.md),
  # so a trigger-pattern clause in it does nothing.
  desc=$(fm_get "$f" "description" --block)
  desc_len=${#desc}
  _gated=$(fm_get "$f" "disable-model-invocation" | tr -d ' ')
  if [ "$name" != "harness-audit" ] && [ "$desc_len" -gt 20 ] && [ "$_gated" != "true" ]; then
    # Trigger pattern (verb + scenario).
    # Bare-verb descriptions ("Loads the foo skill") auto-trigger on every prompt;
    # require a "when"-clause (Use when… / Trigger when… / ALWAYS trigger when… / Trigger on:)
    # to gate routing. Block-scalar descriptions ARE matched (fm_get --block returns
    # the full body, not just the `|` marker line), so a `Use when…` clause anywhere
    # in a multi-line description satisfies the check.
    if [ -n "$desc" ] && ! grep -qiE "Use when|Use this skill when|Use PROACTIVELY when|Use after|Trigger when|Auto-loads when|ALWAYS trigger|ALWAYS run|Trigger on|Invoke when" <<<"$desc"; then
      warn "skill '$name' missing trigger pattern (e.g. 'Use when…') in description"
    fi
  fi
done

