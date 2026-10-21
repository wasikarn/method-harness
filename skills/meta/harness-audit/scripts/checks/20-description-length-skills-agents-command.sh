#!/usr/bin/env bash
# 20. Description length — skills, agents.
# (commands/ retired as a surface type 2026-08-25 #112 — the commands/*.md
# globs this check used to scan were dropped 2026-09-01, sweep #3 Phase 5.)
# code.claude.com/docs/en/skills + /sub-agents: description max 1536 chars
# (combined with when_to_use). Over-limit is silently truncated by the runtime,
# which can cut off the negation clause and degrade routing. fm_get --block
# returns the full block-scalar body (with indent stripped), so multi-line
# descriptions are measured accurately against the limit.
# Gap, not a live bug (verified 2026-08-29): this only measures `description`.
# Zero surfaces in this repo currently carry a `when_to_use:` field, so nothing
# is undercounted today — but the 1,536-char cap is on the COMBINED
# description+when_to_use text, so a future skill adding when_to_use would need
# this check to sum both fields.
# Also unaccounted for: `skillListingMaxDescChars` (a Claude Code setting) can
# move this 1,536 default the same way check 43 already reads
# skillListingBudgetFraction dynamically from settings. Unset in this repo today,
# so the hardcoded default below is correct for now — would need the same
# settings-lookup treatment if that ever changes.
DESC_MAX=1536
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac
  label=${f##*/}; label=${label%.md}; [ "$label" = "SKILL" ] && { _t=${f%/*}; label=${_t##*/}; }
  desc=$(fm_get "$f" "description" --block)
  len=${#desc}
  if [ "$len" -gt "$DESC_MAX" ]; then
    warn "'$label' description is $len chars (>$DESC_MAX; runtime truncates — trim it)"
  fi
done

# 20.5. Duplicate-surface detector — two surfaces sharing the SAME name: AND a
# near-identical description are a true content twin (the kbg-help skill+command
# dup, removed v0.2.66). Same name with DISTINCT descriptions is a legitimate
# skill↔command twin (e.g. ideate) — NOT flagged. Keys on name to stay
# false-positive-free; similarity is computed via python difflib on the
# description bodies. Fires on ratio ≥ 0.85 OR a ≥ 60-char identical run (a
# copy-pasted "Don't use for…" tail), which the closest-match-wins-wrong
# routing failure (code.claude.com/docs/en/skills) is born from. WARN, not CRIT:
# an intentional twin pair that drifts into similarity is a routing smell, not a
# build-breaker.
_dup_tsv=$(mktemp)
for f in "$CLAUDE_DIR/skills"/*/SKILL.md "$CLAUDE_DIR/skills"/*/*/SKILL.md "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  case "$f" in */skills/_*) continue ;; esac
  label=${f##*/}; label=${label%.md}; [ "$label" = "SKILL" ] && { _t=${f%/*}; label=${_t##*/}; }
  nm=$(fm_get "$f" "name")
  [ -n "$nm" ] || continue
  dsc=$(fm_get "$f" "description" --block | tr '\n\t' '  ')
  printf '%s\t%s\t%s\n' "$nm" "$label" "$dsc" >> "$_dup_tsv"
done
while IFS= read -r finding; do
  [ -n "$finding" ] && warn "$finding"
done < <(python3 - "$_dup_tsv" <<'PYEOF'
import sys, difflib
from collections import defaultdict
groups = defaultdict(list)
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        groups[parts[0]].append((parts[1], parts[2]))
for name, surfaces in groups.items():
    for i in range(len(surfaces)):
        for j in range(i + 1, len(surfaces)):
            (la, da), (lb, db) = surfaces[i], surfaces[j]
            sm = difflib.SequenceMatcher(None, da, db)
            ratio = sm.ratio()
            longest = sm.find_longest_match(0, len(da), 0, len(db)).size
            if ratio >= 0.85 or longest >= 60:
                print(f"duplicate surface: name '{name}' shared by {la} + {lb} "
                      f"({int(ratio*100)}% identical, {longest}-char shared run) "
                      f"— delete one or differentiate the descriptions")
PYEOF
)
rm -f "$_dup_tsv"

