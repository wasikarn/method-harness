---
name: ideate
description: "Parallel divergent ideation (5 isolated agents, rotating frames, novelty/viability/fit scoring). Use when the question is open-ended. Say 'brainstorm'. Not for syntax, lookups, or closed-phrasing asks."
argument-hint: "[problem-statement]"
model: inherit
effort: high
---

# Ideate

Divergent ideation: five isolated generator agents under different cognitive frames, then one
critic agent that scores, clusters, ranks and deepens. Explicit (`mh:ideate <problem>`,
"brainstorm") and auto-routed invocations run the same algorithm.

## Pre-flight gate

A run costs 6 Agent calls (8 on the opt-in host path), 30-90 s, and 5-10x a direct
answer. An imperative request to run it (`mh:ideate <problem>`, "brainstorm", "ideate mode",
"run ideate on this") is opt-in: go straight to Phase 1. Mentioning the skill's name inside a
question about whether to run it is not opt-in; the gate applies. Otherwise ask three
questions and abort on any NO:

1. **Open-ended?** Several viable answers. One canonical answer (syntax fix, known-root-cause
   bug, lookup, "what is the X for Y", "find the file that does X") is a NO.
2. **High-stakes?** The obvious answer is expensive to get wrong (architecture, public API,
   naming, schema, fuzzy debugging). A side project at 11pm is a NO.
3. **Open phrasing?** "quick", "standard", "canonical", "textbook", "just", "one-liner" mean
   the user wants the direct answer: NO.

On abort, answer directly; optionally add one line: *"For a wider exploration under parallel
cognitive frames with explicit trap detection, run `mh:ideate <your problem>`."*
Done when: the brief names either the three YES answers or the explicit trigger.

## Wave structure (load-bearing)

- **Phase 1 Diverge:** 5 parallel Agent calls, peak 5.
- **Phase 2 Focus:** one sequential critic call, which also deepens and so replaces Phase 3;
  on the opt-in host path, score and cluster on the host, no fan-out.
- **Phase 3 Deepen (opt-in host path only):** 3 parallel Agent calls, peak 3.

Peak concurrency 5 is this skill's own design limit (Rule 13 caps at 10). Phase 1 completes before Phase 2 starts; never
collapse Diverge and Deepen into one wave of 8. History of the 44-to-105-agent failure this
guards against: `references/provenance.md`.

## Phase 1: Diverge

1. **Pick 5 frames** from `references/frames.md`. Code-shaped problem: 4 tagged `code` or
   `design` plus 1 tagged `wild`; product or strategy problem: a mix across all tags. Name
   the five in the brief. A re-run on the same problem swaps at least two.
2. **Dispatch 5 parallel Agent calls** (`subagent_type: general-purpose`), one per frame. Each
   prompt is the DIVERGENT block followed by the payload from `references/algorithm-detail.md`,
   Phase 1, copied verbatim. The Agent tool has no separate system prompt; the block goes at
   the top of the prompt. A prompt carries only the problem, optional context, and its own
   frame: never another branch's ideas or a list of the other frames (Isolation invariant).
3. **Wait for all five**, then parse each as a JSON array. A branch that returns nothing
   parseable is reported in the brief as a failed branch, never silently dropped; fewer than 3
   parseable branches stops the run with that fact.
   Done when: every branch is either an idea list or a named failure.

## Phase 2: Focus

1. **Score** every idea on three axes, 0-10, before ranking any (anchoring guard):
   novelty (distance from the obvious default), viability (could it ship), fit (addresses the
   stated problem). Then pipe the scores into `scripts/rank.py` (stdin JSON, see the file
   docstring) for `total`, the shortlist, runner-up and non-obvious pick; viability weighs
   heaviest because unshippable-but-brilliant is the dominant failure mode. Attach a one-line
   `trap` reason to any attractive idea with a hidden cost, false economy, scale ceiling, or
   premature abstraction (confirmation guard: look for why an attractive idea is wrong). `trap`
   is a reason field, never a score threshold.
2. **Cluster** into 3-6 groups by underlying angle, labelled by the angle ("remove-the-server
   plays"), never by surface keyword. A cluster drawn from 3 or more distinct frames is
   independent convergence: say so beside the label.
3. **Shortlist** rank.py's top 3 (traps excluded) with a one-line reason each, the
   runner-up and why it missed, and a confidence level with its reason.

**Who scores.** Every run hands Phase 2 to the `ideate-critic` agent, explicit or auto-fired:
one sequential Agent call (`subagent_type: mh:ideate-critic`) with the envelope in
`agents/ideate-critic.md`; its JSON reply carries every field the output shape renders,
including the three deepened branches, so Phase 3 is skipped. Score on the host and run Phase 3
instead only when the user asks for host scoring ("host scoring", "no critic"). The critic is
pinned to Sonnet (`agents/ideate-critic.md`), so scoring and deepening no longer run on a stronger
host model: fresh context cuts anchoring, and its output is advisory evidence, not ground truth. Done when: every idea has three scores, a cluster, and a trap or none.

## Phase 3: Deepen (opt-in host path)

Dispatch 3 parallel Agent calls (`subagent_type: general-purpose`), one per shortlisted idea,
each prompt the FOCUS block from
`references/algorithm-detail.md`, Phase 3, plus the focus idea and the Phase 1 sibling ideas as a
read-only recombination pool. Never pass another deepen branch's output. Done when: each
returns a sketch, a load-bearing risk, a first concrete step, and 3-5 child ideas.

## Isolation invariant

Diverge branches never see each other. A branch that reads another's output anchors to it and
the method collapses into one wider thought. Siblings are shared only at Phase 3 (or inside the critic's one context), only as a
pool, never as the focus idea. A Diverge or Deepen branch never spawns its own Agent calls:
the branch prompt is the whole task, and a nested wave is the 44-to-105 failure again.

## Output shape

Render in this order; the structure is the point, never a wall of prose. Full per-item
contract: `references/algorithm-detail.md`, Output shape.

1. **Brief**: problem in 1-2 lines, the five frames, any failed branch, the cost line
   ("6 Agent calls", or "8" on the opt-in host path; advisory, not metered).
2. **Wide set**: clusters with angle labels, one phrase per idea, score chips `[N7 V8 F9]`,
   convergence notes.
3. **Converge**: the 3 shortlisted ideas with reasons, ★ on the non-obvious-but-viable pick with its
   reason, confidence, runner-up, traps listed separately with their reasons.
4. **Focus**: the 3 deepened branches.
5. **Provocation**: one wildcard, *"What if we took this seriously: <highest-novelty survivor>"*.

## Phase 4: follow-up (opt-in)

When the user replies asking to deepen one idea, re-run with named frames, or combine two ideas,
run the matching short pass in `references/phase4.md` (1-3 Agent calls) instead of a full run.
Never offer it unprompted.

## Failure modes

- **Decoration, not divergence.** Ten variations on one assumption. Spread the frame picks.
- **Refusing to commit.** "Here are 30 ideas, you decide" is a cop-out; converge with an opinion.
- **Sequential branches in one context.** That is one wider thought, not ideate. Use Agent calls.
- **Silent parse failure.** An empty branch reported as a run that succeeded.
- **Judge as ground truth.** Same model class scored it; the user remains the gate.

## Bundled resources

- `references/algorithm-detail.md`: the literal DIVERGENT and FOCUS prompt blocks, payload,
  rubric mechanics, rendering contract. **Load before dispatching.**
- `references/frames.md`: the 15 frames with tags. **Load at Phase 1 step 1.**
- `scripts/rank.py`: the deterministic ranker both scoring paths run. `--selftest` checks it.
- `references/phase4.md`: the three follow-up patterns. **Load only on a follow-up.**
- `references/provenance.md`: upstream citations, cap history, eval rigor limitation. Not
  needed to run.
