#!/usr/bin/env bash
# 4. Frontmatter completeness — agents
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  if ! grep -q '^---' "$f"; then
    crit "agent '$name' missing frontmatter"
  fi
  if [ -z "$(fm_get "$f" "name" --block)" ]; then
    crit "agent '$name' missing name: in frontmatter"
  fi
  if [ -z "$(fm_get "$f" "description" --block)" ]; then
    crit "agent '$name' missing description: in frontmatter"
  fi
  # bucket: groups agents by role (design/review/build/analysis/utility).
  # Missing it does not break loading: WARN, not CRIT.
  _bucket=$(fm_get "$f" "bucket")
  # Trim surrounding whitespace before checking (2026-08-31 deep-audit: an
  # untrimmed trailing space, e.g. from a copy-paste, made `fm_get` return
  # "review " — non-empty, so it reached the enum check below and false-WARNed
  # as "unrecognized". Trimming first also means a whitespace-only value
  # ("bucket:   ") now correctly falls into the missing-bucket branch instead
  # of reporting a bogus non-empty "unrecognized bucket: '   '").
  _bucket="${_bucket#"${_bucket%%[![:space:]]*}"}"
  _bucket="${_bucket%"${_bucket##*[![:space:]]}"}"
  if [ -z "$_bucket" ]; then
    warn "agent '$name' missing bucket: in frontmatter"
  else
    # Enum check (2026-08-31): the non-empty check above only proves a value
    # is present, not that it's one of the 5 recognized agent buckets — a typo
    # like `bucket: reveiw` passed silently, falling into "unbucketed" with no
    # warning at all. Same severity as missing (grouping-only impact; agents
    # stay flat/always-discoverable regardless of bucket value, unlike check
    # 05's skill folders where an unrecognized bucket dir is undiscoverable).
    # Case-folded (2026-08-31 deep-audit: `bucket: Review` is an innocent case
    # variant, not a typo, but false-WARNed before this fix) — the message
    # still shows the original untouched value, only the comparison folds.
    case "${_bucket,,}" in
      design|review|build|analysis|utility) : ;;
      *) warn "agent '$name' has unrecognized bucket: '$_bucket' (expected one of design/review/build/analysis/utility)" ;;
    esac
  fi
  # "Daisy" placeholder — exclude audit skill which documents this check — specific Anthropic upstream pattern
  if [ "$name" != "harness-audit" ] && grep -qi 'Daisy\|\\bdaisy\\b' "$f"; then
    warn "agent '$name' contains upstream 'Daisy' placeholder"
  fi
done
