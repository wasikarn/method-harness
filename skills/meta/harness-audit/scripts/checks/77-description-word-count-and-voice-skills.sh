#!/usr/bin/env bash
# 77. Description word count + third-person voice — skills, agents.
# skill-authoring-conventions.md: "Description cap: 25 words, third person." mh's own
# token-budget rule (descriptions ride in every session's context) — distinct from check 20
# (1536-char runtime truncation limit) and check 43 (cumulative listing budget); neither
# of those checks word count or voice. WARN only: a style convention, not a runtime cap.
# "Third person" here means no I/we/you-class pronoun (the token list in the loop below) — a bare
# imperative clause ("Use when …") is NOT a violation; check 05 requires exactly that clause.
# Known false-positive class (mh:deep-audit F4, 2026-09-24, left unfixed — WARN only, no
# live hit today): grep -i makes bare "I" match "i.e."/"I/O"/"us-east-1"/"en-US", and "me"/
# "my" match a quoted first-person trigger phrase like "help me plan". A description that
# needs one of these will false-positive; rewrite around it or accept the WARN.
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac
  label=${f##*/}; label=${label%.md}; [ "$label" = "SKILL" ] && { _t=${f%/*}; label=${_t##*/}; }
  desc=$(fm_get "$f" "description" --block)
  [ -z "$desc" ] && continue
  # read -d "" returns 1 at EOF; the || true keeps set -e (audit.sh) from killing the run.
  read -rd "" -a _w77 <<<"$desc" || true; words=${#_w77[@]}   # word count without wc|tr spawns
  if [ "$words" -gt 25 ]; then
    warn "'$label' description is $words words (>25; skill-authoring-conventions.md caps it — trim or move detail into the body)"
  fi
  # Whole-token match of the pronoun list, no grep spawn: \b word chars are [[:alnum:]_],
  # so split on the rest and match whole tokens (I'm/we're/... reduce to I/we/... at the quote).
  _hit77=0; _tok77=${desc//[^[:alnum:]_]/ }
  for _t77 in $_tok77; do
    case "${_t77,,}" in i|me|myself|my|mine|we|our|ours|ourselves|us|you|your|yours|yourself|yourselves) _hit77=1; break ;; esac
  done
  if [ "$_hit77" = 1 ]; then
    warn "'$label' description uses first/second-person phrasing — skill-authoring-conventions.md requires third person"
  fi
done
