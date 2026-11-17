# Skill-chain workflows proposal adoption audit (2026-11-17)

**Date:** 2026-11-17
**Source:** a self-authored session proposal (pasted text, not an external document): saved Claude Code Workflow scripts that sequence `mattpocock-skills` and tools (six workflows: feature-ship, bug-fix, research-first, pr-review, design-deepen, session-wrapup). Read from a saved copy in the session scratchpad. No pinned revision; matt skills read from the 1.3.2 plugin cache; repo at develop `fa8a9f86`.
**Verdict:** Do not build the six workflows. Total 54/100, **FAIL** against a 65 threshold. The problem is real: skills do not fire unprompted (0 of 20, 0 of 15 in this repo's own runs). But the repo already holds a deliberate deferral, a measured no-headroom result or a prior deleted attempt for five of the six workflows, and the design contradicts three constraints the proposal itself cites (main-session-only spawners, a detached script that cannot pause, user-only skills). Only two things are new: a script-level tool-order assertion (#3) and one entry point for the user-only skills. Keep the proposal's own gate: a blind bare-Claude pilot first, per workflow, before any script.
**Score:** 54.0/100 — **FAIL** (threshold 65; confidence medium). Full criteria table: see Decision score below.

Every claim below about the source's internals is what it describes as of this read, not a verified fact about the source as it exists today or in the future.

## Method

Phase 1: two isolated read-only `general-purpose` agents (A: claims, B: repo fit). Phase 2: one fresh read-only attacker (`opus`) re-checked both against primary evidence; its verdict passed `check-verdict.py` and `check-citations.py`, and `git status --porcelain` was empty before and after. Prior coverage check: `docs/research/` grep and a qmd query found no earlier audit of this proposal. The closest prior work is `docs/research/ideate-workflow-study-2026-11-12.md` (skill vs workflow form, one skill only); this audit increments on it and does not relitigate it. The source is self-authored, so there is no external primary source: "fidelity" here means how well its factual claims about this repo and the plugin cache hold up.

## Claim-by-claim: the facts hold, the cure and two details do not

Legend: `MATCH` = claim confirmed against primary evidence · `PARTIAL` = partially confirmed · `GAP` = claim not found / contradicted by primary evidence · `N-A` = not applicable to this repo.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| 1 | Most matt skills are `disable-model-invocation: true`; the seven named are all flagged | Yes — observed directly (23 of 38 flagged; 7 of 7) | Plugin cache 1.3.2 | MATCH |
| 2 | A flagged skill cannot be called through the Skill tool | Author-asserted | Only global `CLAUDE.md` says so; no probe | insufficient evidence |
| 3 | The `to-spec → to-tickets → implement` order lives only in prose | Yes — observed directly | `integration-map.md:25`; but `implement` already calls `tdd` and `code-review` (`implement/SKILL.md:11,15`), so #1 risks a double review | PARTIAL |
| 4 | `code-review`, `grilling`, `research`, `implement-spec` spawn subagents; main session only | Yes — observed directly | Broader than stated: `improve-codebase-architecture` and `wayfinder` spawn too; `implement`, `grill-with-docs`, `triage` reach spawners via Skill | MATCH |
| 5 | Depth limit is 1, so a spawner in a subagent "silently loses isolation" | Yes for the limit; wording Author-asserted | Operator setting, `~/.claude/settings.json:22`, plus `hooks/gates/subagent-spawn-guard.sh:2`; repo says "denies", not "silently" | PARTIAL |
| 6 | Rule 13 makes a step without `checked[]` fail | Author-asserted | Rule 13 scopes `checked[]` to a validator's return on a builder touching 2+ files or a test (`docs/METHODOLOGY.md:26`), not every step | PARTIAL |
| 7 | "Bare Claude 0.85" gates new surfaces | Yes — observed directly | `composer-not-creator.md:36`: build at 0.85 or lower; proposal says "reaches 0.85, don't build" and pilots script-vs-no-script, not bare-only | PARTIAL |
| 8 | A per-step "qmd before WebSearch" assertion | Author-asserted | No hook enforces tool order today (grep of both hook sets); but documented `agent()` returns only text or schema, so a script cannot see tool calls | GAP |
| 9 | Skills and tools fire inconsistently unprompted | Yes — observed directly (skills/agents only) | `ideate` 0/20 unnamed vs 20/20 named; silent-failure agent 0/15; qmd-order never measured | PARTIAL |
| 10 | Embedding `SKILL.md` in an `agent()` prompt equals invoking it | Not independently checkable | No probe; scripts have no filesystem access | insufficient evidence |
| 11 | Workflow #5 starts from model-driven steps | Contradicted | `improve-codebase-architecture` is user-only and spawns (`SKILL.md:27`); the source's flagged list omits it | GAP |

## Shipped

Nothing — this is a read-only research pass. The only new file is this artifact.

## Deliberately not shipped

- **Workflow #1 feature-ship** — `docs/reference/mattpocock-integration-map.md:21,25` (deliberate "mh names no step of it"); `implement` already runs `tdd` + `code-review`. Anchor: composer-not-creator + YAGNI. Labeled: **deferred**.
- **Workflow #2 bug-fix** — `docs/METHODOLOGY.md:15-17,26-27` already sequences it; `diagnosing-bugs/SKILL.md:26` already includes the failing test. Anchor: Rule 4. Labeled: **premise dead** (already covered).
- **Workflow #3 research-first (as a workflow)** — order is advice only (`CLAUDE.md:34-36`); the assertion idea needs a mechanism the `agent()` API does not document. Anchor: `docs/reference/operating-model.md:40-41` (no doc may claim a check enforces a rule without a gate file). Labeled: **deferred** (pilot qmd-order compliance first).
- **Workflow #4 pr-review** — `docs/reference/branching-model.md:42-132`, `scripts/merge-pr.sh:290,349` already bind the verdict to the head SHA; `evals/README.md:626-658` pilot found bare Claude 0.97/0.97/0.97/1.00 on blind cases (one 0.80 case was not blind), no review workflow built. That pilot tested a finder/refuter workflow, not #4's exact sequence, so this is indirect. Anchor: composer-not-creator headroom rule. Labeled: **declined on evidence**.
- **Workflow #5 design-deepen** — integration map `:13,:16,:17` leaves `improve-codebase-architecture` unrouted on purpose. Anchor: YAGNI. Labeled: **deferred**.
- **Workflow #6 session-wrapup** — map `:23`; `skills/meta/learn/SKILL.md:84` already runs `mh:memory-lint`. Anchor: composer-not-creator. Labeled: **deferred**.
- **A script that "owns the order" including main-session-only and one-way-door steps** — `docs/research/loop-graph-engineering-trend-audit-2026-08-02.md:193-194` (a Workflow runs detached, cannot pause); `hooks/gates/subagent-spawn-guard.sh:2` keys on subagent identity. Anchor: Rule 1 (one-way doors need approval). Labeled: **premise dead**.

## Decision score (METHODOLOGY Rule 14)

Primary weight is the largest by rule. Fit carries 30: the decision is whether the repo needs this, and prior removals make that the main risk. Blast radius carries 25: adoption is mostly an eval spend, so cost of being wrong is moderate. Pass threshold 65; fatal-weakness floor 40% of each criterion's max (4 of 10).

| Criterion | Weight | Score | Reason |
|---|---|---|---|
| primary-source-fidelity | 45 | 6/10 | Anchors: 3 = core facts contradicted; 8 = facts and details match. Core facts match (skill flags 23/38, spawners, depth setting, no tool-order hook). Misses: 0.85 rule restated wrongly, Rule 13 over-generalised, "silently" unmeasured, #5's first step unflagged, tool-assertion unsupported by the documented API. |
| fit | 30 | 4/10 | Anchors: 3 = need duplicated and design contradicts constraints; 8 = unmet need, design fits. Real need (skills 0/20 and 0/15 unnamed) but five of six workflows are covered or deferred, workflow form was removed three times (`84f96c72` 29 files, `10b6230f`, the Aug orchestrate plan) and tied on ideate; only #3's assertion and a user-only entry point are new. |
| blast-radius-reversibility | 25 | 6/10 | Anchors: 3 = machine-wide, hard to undo; 8 = one file, trivially undone. The recommended step (a pilot) is T1 spend (~6 USD bare-only per `evals/README.md`). A build adds a `workflows/` dir (check 70 WARN), a 6th ADR, map edits, and a T3 plugin update; removal last time touched 29 files. |

Weighted sum: 45×0.6 + 30×0.4 + 25×0.6 = 27 + 12 + 15 = **54.0/100**. Pass threshold 65; floor 4/10 — no criterion strictly below it (fit sits exactly on it), source side not tripped. **FAIL.** Confidence: medium (one attacker pass, two analysts, no live probe of a workflow agent calling `Skill`).

## Open questions

- Can a Workflow agent call a model-invocable `Skill`, and is embedding a flagged `SKILL.md` equivalent to invoking it? — revisit only after a one-run probe with a throwaway plugin, as in `ideate-workflow-study-2026-11-12.md:119-126`.
- Does bare Claude skip qmd-before-WebSearch, and how often? — revisit only after a blind bare-only case set with a hashed grader exists; no measurement today.
- Does an Agent call from a workflow agent get denied by `subagent-spawn-guard.sh`? — revisit with a probe; currently an inference from the `git stash` denial.

<!-- Reserved: a later pass appends a dated correction here, never rewrites the sections above.
**Correction (date, mechanism):** ... -->
