# "When to fold subagents into your main agent loop" adoption audit, mh pass (2026-10-27)

**Date:** 2026-10-27
**Source:** Anthropic article, 2026-10-22,
claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop.
The raw HTML was fetched with curl on 2026-10-27 (575,829 B, no banner). Companion kit:
github.com/anthropics/single-agent-loop-kit, default branch `release`, read through `gh api`. No
pinned revision.
**Verdict:** Fold the two agents that make or write plans, `code-architect` and
`performance-optimizer`, into skills, but add chain cases first. Keep the rest as subagents.

- `backend-architect` and `requirement-analyst` also scored "not worse" when folded in this
  morning's eval, but they don't qualify. `backend-architect` grades work (maker ≠ checker).
  `requirement-analyst` is a read-only boundary around untrusted ticket text. The eval measured
  neither property.
- The article's evidence is mostly vendor anecdote. Its one checkable anecdote, the folded agent
  that skipped the shipping call, may be run-to-run noise.

The decision rests on mh's own fold eval, not on the article.
**Score:** 61.5/100 — **PASS** (threshold 60; confidence medium). Full table: Decision score below.

Every claim below about the source is what it says as of this read. It is not a verified fact
about the enterprise deployments it describes.

## Method

This pass builds on the earlier audit and does not relitigate it.

**Prior audit.** `~/Codes/Personals/dotfiles/docs/research/fold-subagents-article-audit-2026-10-26.md`
scored 65/100 PASS. It recommended a fold-vs-keep eval for four mh agents, which shipped as
`scripts/eval-fold.sh` (90ff40ca, PR #701).

**Fold eval result.** The eval ran on 2026-10-27 at `--runs 2`. Results are in
`~/Codes/Personals/method-harness/evals/results/fold-*/compare.txt` (gitignored).

**What this pass adds:**
- the attacker's doctrine findings on two of the four candidates
- the chain-coverage gap
- a reading of the kit's raw logs

**Withdrawn draft.** An earlier draft from this same session was written before any of the above
was found. It recommended a code-architect "pilot" that had already run, so it was withdrawn.
That draft was one session's own analysis, with no independent check.

**Agents:**
- **Phase 1:** two isolated, read-only `general-purpose` analysts. Agent A covered claims and Agent
  B covered fit. Neither saw the withdrawn draft. Agent A's phrase "hundreds of overlapping
  subagents" is confirmed in the saved copy.
- **Phase 2:** a Codex attacker (`gpt-6.1-sol`, medium effort, `--sandbox read-only`). It exited
  0, `check-verdict.py` exited 0 and `check-citations.py` exited 0. The tree was unchanged before
  and after. The verdict was `pass: false`, with 6 findings and 16 `checked[]` items.

**Untrusted-source check.** The article has no text aimed at an agent reader. The kit's
`CLAUDE.md:8` does tell agents what not to open during an audit. That only applies to someone
running the kit, so it was treated as data, not followed.

## Claim-by-claim: the tools are real, the results are anecdote, and the one checkable anecdote may be noise

Legend: `MATCH` = core assertion and details corroborate · `PARTIAL` = core corroborates, a named
detail doesn't · `GAP` = contradicted or unsupported · `N-A` = not relevant to this decision.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| 1 | A single agent with skills often beat subagent designs on quality, cost and latency | Author-asserted. The cited link is a text fragment that quotes the same sentence in another Anthropic article. | No local data except the fold eval (row 9) | N-A |
| 2 | Keep a subagent for context bloat, for parallel fresh contexts, or when the agent struggles with tool choice or conflicting instructions. Black-box verification is a good split. | Yes. Attacker re-checked it in the decoded HTML. | Matches the verifier half of operating-model.md §2. The kit's own list drops "tool trouble" and adds "reads far more than needed afterwards". | MATCH |
| 3 | The plan writer should also execute the plan | Author-asserted | mh has no orchestrator layer (operating-model.md "No orchestration layer of its own"). The ADR that said "main never executes" was reversed in the v1 rebuild. | N-A, no conflict |
| 4 | One customer saw about 2x faster runtime | Not independently checkable | The kit's recorded fold run shows 1.41x (27.31 s → 19.36 s), by Agent A's recompute, confirmed by the attacker | PARTIAL |
| 5 | A fold broke a passing task, the delivery date was skipped, and it showed in 1 of 2 runs | Yes, the kit traces match | The same t01 rep-1 failure also shows in the unrelated as-tool run, and 8 extra t01 reps passed (attacker confirmed). So the break may be noise. | PARTIAL |
| 6 | Lower cost | Partly shown | The kit's input tokens did not fall (435,707 → 436,880). Output tokens (36,941 → 25,235) and model calls (152 → 116) did fall. | PARTIAL |
| 7 | Tool choice degrades past 30-50 tool definitions | Author-asserted | No measurement in the article or the kit. Tool search is already on here. | GAP as a rule |
| 8 | `/skill-doctor`, the `/claude-api` sub-skills (build-eval, prompt-audit, hillclimb, cost-optimize) and `/skill-creator` exist | Yes, found as strings in CLI 2.1.311 | Present but not run. `/skill-creator` is a plugin, which the article doesn't say. | MATCH as presence only |
| 9 | Keep the subagent only if the folded version scores worse | A decision rule, not a finding | Applied this morning: 0 "folded worse" across 20 cases at N=2 for all four agents. One "folded better" each for code-architect and performance-optimizer. | N-A, applied |
| 10 | Cover every production chain before each change | Author-asserted, and the kit's own first run missed a chain | **No fold case covers a chain.** requirement-analyst → code-architect (CHANGELOG.md:11377-11381) and code-architect → plan-reviewer (agents/plan-reviewer.md:40) are untested. | GAP locally |

## Shipped

Nothing. This is a read-only research pass. Folding an agent deletes a shipped surface and
changes the README agent count that check 79 pins, so it needs a plan and approval first.

## Recommended, in order

1. **Add chain cases to the fold eval** (T1). At minimum:
   - code-architect's blueprint feeding plan-reviewer
   - requirement-analyst's verdict feeding code-architect

   Re-run code-architect and performance-optimizer at `--runs 3` (the runner's default). A single
   flip at N=2 is weak evidence either way.
2. **Fold `code-architect` and `performance-optimizer` into skills if step 1 holds.** Each is one
   PR, and both are reversible. A deleted agent was restored the next day before (df2cc58a →
   0f09c1c1). Live files to touch, from Agent B's grep:
   - the agent file and its 6 eval cases
   - the agent lists in operating-model.md, agent-authoring-conventions.md and
     mattpocock-integration-map.md
   - README.md and evals/README.md
   - `tests/evals/test-eval-cases.sh` and `tests/scripts/test-eval-fold.sh`
   - check 79's agent-count pin
   - cross-references in agents/backend-architect.md and agents/plan-reviewer.md

   After folding, the performance-optimizer skill's edits still need Rule 13's fresh-context
   validator.

## Deliberately not shipped

- **Folding `backend-architect`.** Its agent file asks for "a scored review" that "stays
  independent of the system it reviews" (agents/backend-architect.md:22, :32). Its eval cases
  hunt defects in an existing design (evals/backend-architect-client-trusted-price/prompt.md:9).
  Once `code-architect` folds, the main session writes the blueprint. Then `backend-architect`
  and `plan-reviewer` would be reviewing the main session's own work, so folding the planner is
  what makes their independence matter. The fold eval scored output, not independence.
  Doctrine: maker ≠ checker (operating-model.md:76-79, agent-authoring-conventions item 4).
  **Declined on evidence.**
- **Folding `requirement-analyst`.** Its tool grant is only Read, Grep and Glob, and it treats tickets as
  untrusted (agents/requirement-analyst.md:5, :13). A folded skill runs with the main loop's full
  tools. The fold eval ran folded arms without the agent's `tools:` limit and had no injection
  case. Doctrine: agent-authoring-conventions item 2 (Prompt Defense Baseline, OWASP LLM01).
  **Declined on evidence**, unless a folded arm passes an injected-ticket case.
- **Folding or merging the verifiers** (blind-spot-hunter, plan-reviewer, ideate-critic,
  silent-failure-hunter, test-gap-analyzer, type-design-analyzer). These are the article's own
  "black-box verification" keep case (row 2). They also fall under mh's rule that reviewers stay
  read-only and fresh-context (operating-model.md:78-79). A merge of the three diff lenses must
  also keep the NOTICE:4-8 attribution. Doctrine: maker ≠ checker. **Declined on evidence.**
- **Central team, per-team DRIs, the 30-50 tool ceiling, routing-accuracy evals.** One operator
  and no router agent. Tool search is already on. Settled in the prior audit's "Deliberately not
  shipped" section (`~/Codes/Personals/dotfiles/docs/research/fold-subagents-article-audit-2026-10-26.md`).
  Doctrine: YAGNI. **Premise dead.**
- **Running the kit itself on mh.** Its scripts expect API orchestration code and a trace export.
  Its README says it has never run on any system but its toy example (kit `README.md:145-148`).
  The cost log and `eval-fold.sh` already cover its audit and compare steps. Doctrine:
  composer-not-creator, YAGNI. **Declined on evidence.**

## Decision score (METHODOLOGY Rule 14)

Decision scored: recommendations 1 and 2 as written. Pass threshold 60. The fatal-weakness floor
trips when a criterion scores below 40% of its own max.

| Criterion | Weight | Score | Reason |
|---|---|---|---|
| primary-source-fidelity | 40 (largest: the adoption rests on whether the claims hold) | 6/10 | All named tools exist, and the thinking claims are confirmed in the CLI's bundled docs. The enterprise results are anecdote. The one checkable anecdote (row 5) may be noise, and the cost claim is half shown. A 3 would be mostly unverifiable claims. An 8 would be measured results with a stated method. |
| fit | 25 (does mh have the need) | 6/10 | mh has no orchestrator to fold, and only 2 of its 10 agents are fold targets once doctrine applies. A 3 would be enterprise-only advice. An 8 would be a live pain point, such as a router agent. |
| local-fold-evidence | 20 (the article's own decision rule runs on it) | 6/10 | 0 "folded worse" in 20 cases, at about half the cost for code-architect ($5.85 → $2.73). But N=2, there are no chain cases and there is no tools-limit parity. A 3 would be no eval. An 8 would be chain cases plus runs ≥ 3. |
| blast-radius-reversibility | 15 (cost if adopted and wrong) | 7/10 | Git-revertible, with restore precedent. About 12 live files per agent, plus check 79. Plugin users only see it after a version bump. A 3 would be removing a gate or verifier with no eval. A 9 would be docs only. |

`weighted-score.py`: 0.40×60 + 0.25×60 + 0.20×60 + 0.15×70 = 24 + 15 + 12 + 10.5 = **61.5/100**.
`belowFloor` is empty, `primaryWeightOk` is true and the source side is not insufficient.
**PASS.** Confidence: medium. One independent Codex pass ran and the eval is real, but it covers
only 2 runs and 20 single-agent cases.

## Open questions

- Does a folded code-architect still hand plan-reviewer a blueprint it can attack? Revisit after
  recommendation 1's chain case runs, not from more reading.
- 41 of blind-spot-hunter's 68 sessions have no deep-audit row, and their dispatcher is unknown.
  Revisit if verifier spend becomes a cost question.
- `/skill-doctor` vs gate-report's skill-usage half: not run. Revisit when gate-report is next
  edited.

<!-- Reserved: a later pass appends a dated correction here, never rewrites the sections above. -->

**Result (2026-10-27, recommendation 1 run):** `scripts/eval-fold.sh` was run at `--runs 3`
(`-j 4` for the two agent runs, `-j 3` for the unprompted case alone), with a per-variant cost cap. It added two chain cases:

- `code-architect-chain-plan-reviewer`: the prompt names the reviewer.
- `code-architect-chain-unprompted`: the prompt asks for a "checked" plan but does not name the
  reviewer.

No run errored or hit its cap. Total cost was $34.36.

| Agent | folded worse | folded better | same | Cost kept / folded | Flipped grader |
|---|---|---|---|---|---|
| code-architect (8 cases) | 0 | 2 | 6 | $17.21 / $8.34 | `di-style-match` FPP → PPP, `no-speculative-interface` FFF → PFF |
| performance-optimizer (6 cases) | 1 | 1 | 4 | $4.31 / $4.49 | `measured-fix-quality` FFF → PPP, `no-shallow-copy-quality` PPP → PFP |

What the chain cases showed:

- Both chain cases passed in all 3 runs of both arms (PPP).
- In the unprompted case, both arms called `mh:plan-reviewer` on their own, and every check came
  from a fresh context.
- The folded arm's `DELEGATED` line counts exactly those reviewer calls, one per run.
- So in this case, folding the planner did not skip the next specialist.

What `performance-optimizer`'s "folded worse" means:

- The one worse case is `perf-shallow-copy-trap`, and it rests on a single failed run out of 3.
  This morning's N=2 run (`fold-performance-optimizer-20261027T075749`) flipped the other way
  (kept FP, folded PP).
- Across all 5 runs, both arms pass 4 of 5.
- Read per case, the adopted rule says keep the agent. Read by outcome score, folded is ahead
  (summed over 6 cases: 5.67 vs 5.00; mean 0.94 vs 0.83).

Results (gitignored, local only):
`evals/results/fold-code-architect-20261027T092413/compare.txt`,
`evals/results/fold-code-architect-20261027T123727/compare.txt` (the unprompted case alone),
`evals/results/fold-performance-optimizer-20261027T122715/compare.txt`.

What this changes, against the sections above:

- **Recommendation 1 is half done, on purpose.** The requirement-analyst → code-architect chain
  case was dropped. requirement-analyst stays a subagent (see "Deliberately not shipped"), so
  folding code-architect leaves that handoff's boundary in place.
- **code-architect now has 8 eval cases, not 6** (the two chain cases).
- **Re-score.** local-fold-evidence moves from 6 to 8, because its own 8-anchor ("chain cases
  plus runs ≥ 3") is now met. `weighted-score.py`: 0.40×60 + 0.25×60 + 0.20×80 + 0.15×70 =
  **65.5/100, PASS**, up from 61.5. Floor clear. Confidence stays medium: it is still N=3 on
  single-agent cases, with one chain.
- **performance-optimizer decision.** The operator approved folding it on 2026-10-27, against a
  strict per-case reading of the rule. The reason: the single "folded worse" case rests on one
  run and reversed the earlier run's direction, while `perf-nested-loop-fix` flipped FFF → PPP.
  The Verdict's two-agent fold stands.
