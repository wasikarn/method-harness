# Idea-audit artifact template

Load before writing the Phase 4 artifact. Fill every section; drop none. Usually no frontmatter —
most of this repo's `docs/research/<topic>-audit-<date>.md` files have none, though a few do
(including the exact file SKILL.md Phase 3 names as the scoring-table shape to copy); frontmatter
is not a hard requirement either way, match whichever this artifact's own topic is closer to.

```markdown
# <source name> adoption audit (<date>)

**Date:** <date>
**Source:** <URL or description>, fetched/read <date>. <For a repo/tool: local clone? pinned
revision? State the negative form explicitly if not — "No local clone, no pinned revision — the
repo carries no release tag as of this read.">
**Verdict:** <one paragraph, opinionated, stated plainly>
**Score:** <total>/100 — **<PASS/FAIL>** (threshold <N>; confidence <high/medium/low>). Full
criteria table: see Decision score below.

Every claim below about the source's internals is what it describes as of this read, not a
verified fact about the source as it exists today or in the future.

## Method

<N agents, fresh-context or not, read-only or not. State whether this pass increments on a prior
audit or relitigates it, citing the prior doc by path if one exists. Cite the qmd prior-coverage
check if run.>

## <Claim/component>-by-<claim/component>: <the actual finding this table shows, not a topic label>

Legend: `MATCH` = claim confirmed against primary evidence · `PARTIAL` = partially confirmed ·
`GAP` = claim not found / contradicted by primary evidence · `N-A` = not applicable to this repo.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| 1 | <claim text> | <Yes — observed directly / Author-asserted / Not independently checkable / insufficient evidence> | <what's already true here, or the gap> | <MATCH/PARTIAL/GAP/N-A> |

## Shipped

<version bump or commit SHA, or explicitly: "Nothing — this is a read-only research pass" plus the
reason.>

## Deliberately not shipped

- **<item>** — <file:line / ADR / commit citation> **and** <named doctrine anchor: a METHODOLOGY
  rule, YAGNI, maker≠checker, an ADR>. Labeled: **deferred** / **declined on evidence** /
  **premise dead**.

## Decision score (METHODOLOGY Rule 5)

| Criterion | Weight | Score | Reason |
|---|---|---|---|

Weighted sum: <arithmetic shown> = **<total>/100**. Pass threshold <N>, fatal-weakness floor <N> —
<state whether any criterion is below the floor, and whether the source side tripped it per
SKILL.md Phase 3's all-`insufficient evidence` rule>. **<PASS/FAIL>.** Confidence: <high/medium/
low> (<basis — sample size, independent review pass, or lack thereof>).

## Open questions

- <item> — revisit only if <an observable event>, not from further reading of the same source.

<!-- Reserved: a later pass appends a dated correction here, never rewrites the sections above.
**Correction (date, mechanism):** ... -->
```
