# ideate — exact prompts, rubric mechanics, output-shape detail

## Contents

- Phase 1 Diverge prompt
- Phase 1 DIVERGENT block
- Phase 3 FOCUS block
- 3-axis scoring rubric mechanics
- Critic invocation
- Output shape

SKILL.md keeps the control flow and every invariant; this file carries the literal templates
read at execution time. Provenance for all of it: `provenance.md`.

## Phase 1 — Diverge prompt (per Agent call)

The Agent tool takes one prompt; put the DIVERGENT block first, then this payload.

```
PROBLEM:
{problem}

{context ? `CONTEXT:\n${context}\n\n` : ""}FRAME — {frame.label}:
{frame.prompt}

Generate 6 ideas under this frame.
Output JSON array only. No prose before or after.
[{"text": "...", "rationale": "..."}, ...]
```

## Phase 1 — DIVERGENT block (top of every Diverge prompt)

> You are in DIVERGENT mode. You are a generator, not a critic.
> Generate 6 short distinct ideas under this frame. Each idea is
> one phrase or one sentence. Do not evaluate. Do not rank. Do
> not hedge. The first three obvious answers everyone would
> give are banned. Push past them into the awkward middle.
> Output a JSON array only. No prose before or after.
> `[{"text": "...", "rationale": "..."}, ...]`

## Phase 3 — FOCUS block (top of every Deepen prompt)

> You are in FOCUS mode. Take one promising idea and connect
> dots. Sketch how it would actually work in 4 to 8 sentences.
> Name the load-bearing risk. Name the first concrete step a
> coder would take. Then generate 3 to 5 sub-ideas that branch
> off (variations, combinations with other domains, things this
> unlocks). Output JSON only.

Below the block, the prompt carries the focus idea and the **sibling ideas** from Phase 1 as a
recombination pool, never another deepen branch's output (SKILL.md, Isolation invariant).

## 3-axis scoring rubric — full mechanics

Formula (port from upstream `engine.ts:135-137`), computed by `scripts/rank.py` on both paths
— the model scores, the script ranks:

```
total = novelty * 0.35 + viability * 0.40 + fit * 0.25
nonObviousPick = argmax over shortlist of novelty + viability * 0.5
```

**Why viability is heaviest:** a brilliant unshippable idea is the dominant failure mode —
viability is the gatekeeper, novelty is the reason we're here, fit is the tie-breaker.

**`trap` mechanics:** the score pass attaches `trap: "<one-line reason>"` to ideas that look
attractive but have a hidden cost. Trapped ideas are EXCLUDED from the top-K shortlist but
REPORTED separately so the user sees why — a machine-claim ("3 traps, 1 unscalable, 1
premature abstraction, 1 false economy") plus the one-line reasons, not a silent
`if (total < 5) drop` heuristic.

**Score chip rendering:** show as `[N7 V8 F9]` next to each idea in the Wide set.

Source: `provenance.md`'s "3-axis scoring rubric source" section.

## Critic invocation (default path)

Collect the Phase 1 `ideas[]` JSON into the envelope in `agents/ideate-critic.md` (give each idea an
`id` `i1`..`iN` and its branch's `frameId` and `frameLabel`; pass `options` `{"topK": 3}`) and pass it as
the whole prompt of one `subagent_type: mh:ideate-critic` Agent call; parse its final message
as JSON (a reply with text outside the braces is a parse failure, reported like a failed
branch) and render the output shape from its returned `scores`, `clusters`,
`shortlist`, `shortlistReasons`, `nonObviousPick`, `nonObviousPickReason`, `runnerUp`,
`confidence`, `traps`, `deepened`, `provocation`. The critic's `deepened` is the Focus
block; Phase 3's three Agent calls run only on the opt-in host path.

## Output shape — full rendering contract

Render in this order after Phase 2 — don't collapse into a wall of prose; the structure is
the point.

1. **Brief + cost estimate.** 1-2 lines on the problem/reframe, then:
   *"Cost estimate: 6 Agent calls (8 on the opt-in host path), ~3k–8k input tokens,
   ~1k–3k output tokens. Actuals vary by problem size."* Advisory heuristic,
   not a metered bill.
2. **Wide set.** Full pool grouped by cluster and angle, one short phrase
   per idea, score chips like `[N7 V8 F9]`. If the critic ran, render its
   `frameCount` next to any cluster ≥3 ("3 frames converged here") — same
   note the host-inline path gives; don't drop it.
3. **Converge.** rank.py's shortlist (top 3, traps excluded) with a stated reason each — the
   critic's `shortlistReasons` verbatim when it ran, else stated directly.
   Mark the non-obvious-but-viable pick with ★ (`nonObviousPickReason` when
   present). Show `confidence` beside the shortlist if supplied. Name
   `runnerUp` in one line if non-null; omit if `null` — don't fabricate one.
   List traps separately with their one-line reasons.
4. **Focus.** The 3 deepened branches: sketch, load-bearing risk, first
   concrete step, child ideas.
5. **Provocation.** One wildcard question/idea for if nothing landed:
   *"What if we took this seriously: {highest-novelty survivor}"*

Source: `provenance.md`'s "Output-shape source" section.
