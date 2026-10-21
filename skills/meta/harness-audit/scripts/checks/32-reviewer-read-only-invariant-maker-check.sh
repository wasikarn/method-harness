#!/usr/bin/env bash
# 32. Reviewer read-only invariant (maker≠checker). An agent whose NAME marks it a
# reviewer/analyzer (reviewer|analyzer|analyst|hunter|critic|judge|checker|architect),
# OR whose declared `bucket:` frontmatter is review/analysis, must NOT grant
# Write or Edit: a verifier that can mutate what it reviews defeats the fresh-context
# independence maker≠checker depends on. Load-bearing doctrine: CLAUDE.md's Operating
# model paragraph, under its Architecture section (the L3 bounded-autonomy build it
# came from was retired; the maker≠checker rule survives there) — these agents
# run unattended inside the loop's Gate-2 review. The source frontmatter is read-only
# today (fix 5c06590); this is the regression guard against a future re-widening.
#
# 2026-09-20 audit: name-substring alone is latent -- a future review/analysis-
# bucket agent named e.g. "dependency-scanner" or "race-detector" would carry a
# Write/Edit grant past this check with a clean audit. OR the bucket-field check
# in (declared role drives the invariant, not just a naming convention); keep
# the name check too, since bucket: is optional (check 04 only WARNs if it's
# missing) and this check must still fire for an agent that omits it.
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  # Same trim+casefold as check 04's bucket enum check, so an untrimmed or
  # differently-cased value doesn't silently fall through either branch here.
  _bucket=$(fm_get "$f" "bucket")
  _bucket="${_bucket#"${_bucket%%[![:space:]]*}"}"
  _bucket="${_bucket%"${_bucket##*[![:space:]]}"}"
  is_reviewer=0
  case "$name" in
    *reviewer*|*analyzer*|*analyst*|*hunter*|*critic*|*judge*|*checker*|*architect*) is_reviewer=1 ;;
  esac
  case "${_bucket,,}" in
    review|analysis) is_reviewer=1 ;;
  esac
  [ "$is_reviewer" -eq 1 ] || continue
  tools=$(fm_get "$f" "tools" --block)
  [ -n "$tools" ] || continue
  bad=""
  for t in $(printf '%s' "$tools" | tr ',' ' '); do
    case "$t" in Write|Edit|write|edit) bad="$bad $t" ;; esac
  done
  bad="${bad# }"
  if [ -n "$bad" ]; then
    crit "agent '$name' is a reviewer but grants '$bad' — read-only invariant (maker≠checker) broken; reviewers must not mutate what they review (CLAUDE.md's Operating model paragraph, under its Architecture section)"
  fi
done

