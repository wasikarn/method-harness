# Ideate — Provenance & Cross-References

## Contents

- 2-wave fan-out audit history
- Phase 1 algorithm-shape source
- Phase 2 critic-routing source
- Output-shape source
- 3-axis scoring rubric source
- Isolation invariant source
- Cost source
- Retired advisory hooks
- Cross-references

Upstream algorithm-shape citations (`/tmp/adhd-repo/...` paths are the port-time checkout,
2026-06, not a live path), the fan-out cap's audit history, and pointers to related kbg
surfaces — kept out of `SKILL.md` to stay under its size budget.
None of this is needed to execute a run; it's why the design is shaped the way it is.

## 2-wave fan-out — audit history

The 2026-06-12 audit caught a 44→105-agent failure mode where a
soft cap on a work-list was silently doubled by an audit + verify
layer (operator memory store, `bounded-agent-spawning` and
`whole-repo-dig-2026-06-16`; not in this repo). `evals/ideate-run/`
bounds Agent calls per run (6) but cannot see wave shape; what Rule 13
provides is narrower than a fixture would claim: its hard cap is injected prose, no hook, that
tells the lead to clamp any single wave's work-list to ≤10 before spawning (≤5 until 2026-10-05;
this skill keeps its own 5-agent design limit). This command's Phase 1 (5)
and Phase 3 (3) sizes are written to sit inside that per-wave
clamp. The "exactly 2 waves, not 3+" shape is this skill's own
design contract (Phase 1 through Phase 3 in `SKILL.md`), not
something Rule 13 polices — Rule 13 caps how big a wave can get, not
how many waves a skill runs.

## Phase 1 algorithm-shape source

Source for the algorithm shape: upstream
`/tmp/adhd-repo/skills/adhd/SKILL.md:47-82` and
`/tmp/adhd-repo/src/engine.ts:28-36, 61-101`. The
`kbg-vs-adhd.md` doc (read via Bash: `cat "${MH_PLUGIN_ROOT}/docs/research/kbg-vs-adhd.md"`)
records the port decisions (deterministic frame pick replacing
`Math.random()`, no zod, parse-failure surface-not-swallow).

## Phase 2 critic-routing source

Source: upstream `/tmp/adhd-repo/skills/adhd/SKILL.md:84-112` and
`/tmp/adhd-repo/src/engine.ts:103-175, 177-229`.

**Full rationale** (compact routing rule lives in `SKILL.md`, "Phase 2: Focus", Who scores):

- Host-Claude scoring (Phase 2+3 run on the same model class as the Phase 1
  generators) carries the LLM-judge-circularity caveat from `docs/reference/operating-model.md`'s
  "The maker never grades its own work".
- The critic is the default for every run, explicit or auto-fired. Explicit runs used to score
  on the host (8 calls) because the gate skips stake classification there; the critic path
  costs 6 calls and adds the fresh-context benefit below, so the split was dropped. The host
  path stays as an opt-in ("host scoring", "no critic"). Routing never infers stakes from prompt wording
  like "critical"/"production"; that lexical-heuristic pattern is exactly what `harness-audit`
  already flags as toothless elsewhere.
- Trade accepted (model): `ideate-critic` is pinned `model: sonnet`, so scoring and deepening on
  every run now use Sonnet even when the session model is stronger. Generators still inherit.
- Trade accepted: on the critic path the three deepen branches run inside one critic context,
  not as three isolated Agent calls, so a deepened idea can anchor on the one deepened before
  it, and `deepened[]` folds the load-bearing risk and first step into the sketch prose instead of
  separate fields. The host path keeps that isolation and structure for a user who wants it.
- `ideate-critic` reuses the same scoring rubric but starts fresh, cutting
  the chance the host's own generation anchors the judgment. Its output is
  still advisory evidence, not ground truth — the user is the gate
  (`docs/reference/operating-model.md` §2, "The maker never grades its own work").
- Routing to the critic adds no third fan-out wave: Phase 2 goes from 0
  agent calls (host-inline) to 1 sequential call on the default path, not
  a parallel spawn, and that call returns the deepened branches, so Phase 3
  does not run — the "2-wave, peak-5" design limit (inside Rule 13's cap of 10) is unaffected.

## Output-shape source

Source: upstream `/tmp/adhd-repo/skills/adhd/SKILL.md:145-157`. The
Provocation line's format (`"What if we took this seriously: ..."`) is
from `engine.ts:307-312`.

## 3-axis scoring rubric source

Source: `/tmp/adhd-repo/src/engine.ts:103-147` (why viability is the
heaviest weight) and `engine.ts:275-280` (the upstream "shortlist vs traps"
split that the `trap` free-text field ports from).

## Isolation invariant source

The upstream `engine.ts:251-258` parallel `Promise.all` over a frame list
with no shared state is what preserves this property in the original
implementation.

## Cost source

Source: upstream `/tmp/adhd-repo/skills/adhd/SKILL.md:192-194`.

## Retired advisory hooks (historical)

Three hook-emitted blocks were designed and never shipped past the v1.0.0 rebuild:
`<ideate-rotation>` (SessionStart frame rotation), `<ideate-budget>` and
`<ideate-convergence>` warnings (dropped with the budget/telemetry hooks, v1.0.1), and the
ideate-search companion skill (deleted 2026-09-01; its qmd collection never existed). Frame
rotation is now the "swap at least two on a re-run" rule in `SKILL.md`. Wire a hook first
before any of these is cited again.

## Cross-references

- **Why this exists** — `kbg-vs-adhd.md` (read via Bash: `cat "${MH_PLUGIN_ROOT}/docs/research/kbg-vs-adhd.md"`)
  records the port decisions, the eval-rigor limitation (n=1
  upstream), and the things explicitly rejected.
- **5-agent design limit (load-bearing)** — this skill's 2-wave
  structure is engineered around 5 agents per wave. That was METHODOLOGY Rule 13's
  peak-concurrent cap when the skill was designed (raised to 10 on 2026-10-05); the lead
  applies it by clamping the work-list before spawning, and the skill keeps 5 as its own limit.
- **Fresh-context critic pattern** —
  `agents/ideate-critic.md`
  is the kbg-native critic used for the same-model-critic-circularity
  caveat (`SKILL.md`, "Phase 2: Focus"). Score + cluster +
  deepen are engineered to be re-pointable at this fresh-context
  critic.
- **Methodology on maker ≠ checker** —
  `docs/reference/operating-model.md` §2, "The maker never grades its own
  work"; the verifying agent must be given fresh context.
- **Bounded-agent-spawning precedent** —
  operator memory store, `bounded-agent-spawning`
  — the failure mode this skill's 2-wave cap is designed to
  prevent; full narrative + enforcement caveat in the
  "2-wave fan-out — audit history" section above.
  Not backed by a regression fixture — do not cite one that isn't
  built.
- **Eval rigor limitation (explicit)** — this skill ports
  faithfully from an n=1 upstream demo. The
  `kbg-vs-adhd.md`'s "Eval rigor limitation" section (read via Bash: `cat "${MH_PLUGIN_ROOT}/docs/research/kbg-vs-adhd.md"`)
  is the load-bearing
  disclaimer: treat this as a structured brainstorming tool, not
  a quality-validated generator. That doc is frozen research: its
  `eval/` paths and `skills/ideate/` location predate the 2026-06-27
  reset and the bucket move; the live eval is `evals/ideate-run/`.
