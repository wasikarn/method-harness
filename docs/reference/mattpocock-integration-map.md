# mattpocock-skills integration map

Which installed `mattpocock-skills` skill each mh surface routes to, and which are deliberately
unrouted. Column 2 is `model` (model-invocable) or `user` (`disable-model-invocation: true`,
cited as the literal slash form `/mattpocock-skills:<name>` the user types). Re-verify whenever
the `mattpocock-skills` cache version changes. No check parses this table.

| skill | invocation | mh touchpoint or deferral |
|---|---|---|
| ask-matt | user | the routing layer for "which matt skill" questions; mh ships no router of its own |
| code-review | model | the review surface. Main session only: its internal Standards/Spec fan-out spawns subagents, which native `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` denies from inside a dispatched subagent. Shares its bare name with Claude Code's built-in `/code-review`; the namespaced form is unambiguous |
| codebase-design | model | `skills/design/code-architect/SKILL.md`, `skills/design/backend-architect/SKILL.md` boundary lines (deep-module vocabulary mid-blueprint) |
| diagnosing-bugs | model | METHODOLOGY Rule 4; `skills/workflow/post-mortem/SKILL.md` input contract (Phases 2, 5 and 6 outputs; Phase 6 is the Cleanup checklist) |
| tdd | model | METHODOLOGY Rule 4 |
| domain-modeling | model | `CLAUDE.md` Authoring section (root `GLOSSARY.md` + `docs/adr/`, created lazily) |
| grill-with-docs, improve-codebase-architecture | user | paths into domain-modeling; unrouted from mh prose |
| grilling | model | escalation for a contested call; no mh pointer. Main session only (its research step dispatches a subagent) |
| grill-me | user | `agents/requirement-analyst.md` boundary line (live interview vs analyzing a written requirement) |
| research | model | `CLAUDE.md` research section defers to it after qmd/context7. Main session only |
| implement-spec | user | deferred: parallel whole-spec alternative to `implement` (worktree implementers, one integration branch); mh names no step of it. Main session only (it dispatches implementers, a merger and `code-review`). Its frontier fan-out is uncapped upstream, so wave it at 10 (Rule 13); it has no Rule 13 fresh-context validator (only a merger subagent and a closing `code-review`), so add one for every builder (each builds with `tdd`, so it always touches a test) |
| pr | model | PR-body shape (smallest visual, before/after evidence, merge-danger call); used when writing a PR body; no mh pointer. |
| retro | user | deferred: session retrospective on the agent's environment; overlaps `mh:learn` (cross-turn memory patterns), no mh wrapper. |
| setup-matt-pocock-skills | user | `README.md` Install section. Re-running regenerates its output files from scratch |
| implement, to-spec, to-tickets | user | the spec-to-ship chain; mh names no step of it |
| prototype | model | deferred: no mh surface produces throwaway spikes |
| triage | user | deferred: mh no longer ships a triage-labels doc |
| handoff | user | defers directly to `mattpocock-skills:handoff` — mh ships nothing of its own here. mh briefly shipped its own `handoff` skill, a controlled-path wrapper worked around this skill's lack of a write tool/output path convention, removed in v1.1.94 as a composer-not-creator violation; history in the now-deprecated `docs/adr/0002-mh-controlled-handoff-path.md` |
| writing-fragments | user | `hooks/sensors/fragments-arm.sh`, `hooks/sensors/fragments-capture.sh`, `hooks/session/fragments-surface.sh` — mh detects and captures a **pointer** to this skill's own artifact rather than writing a duplicate, since the artifact is the user's actual creative work. Lives in upstream's unregistered `skills/in-progress/` watch list below — can vanish or reshape without warning. `docs/adr/0003-writing-fragments-pointer-capture.md` |
| wayfinder | user | deferred: its former mh touchpoint was deleted in the v1.0.0 rebuild |
| teach, wait-what, to-questionnaire | user | user↔agent gap-closers with no mh wrapper — each works as a direct `/mattpocock-skills:<name>` invocation. `to-questionnaire` had a real touchpoint pre-rebuild (`CHANGELOG.md`'s `## [0.68.262]` entry, the "graduated `wizard`/`to-questionnaire`" bullet) that was lost the same way `wayfinder`'s was (row above), just never marked `deferred` until this pass caught the stale row-18 citation (2026-09-10) |
| wizard | model | user↔agent gap-closer for manual-only steps (credentials, third-party dashboards); no mh wrapper needed, it reaches for itself the moment a step needs a human (2026-09-10) |
| writing-for-agents | model | `CLAUDE.md` Authoring section; `docs/reference/skill-authoring-conventions.md` |

## Reverse handoffs

Gaps matt names in his own docs that an mh mechanism happens to answer. Partial answers written
up as partial.

1. **research's no cross-session reuse** ("Does a later session reuse what an earlier run found?
   No.") vs mh's qmd-first rule in `CLAUDE.md`: a standing semantic-search-first step. Caveat:
   `qmd` is operator-environment, not bundled.
2. **improve-codebase-architecture's CDN-fragile HTML report** (Tailwind and Mermaid from CDNs,
   breaks silently offline) vs the operator's `diagram-design` skill, whose output is a
   self-contained HTML file. Caveat: third-party, and it replaces only the diagram half.

## Upstream watch list

Unregistered in matt's own `plugin.json` (`skills/in-progress/*`, `skills/misc/*` in the local
clone); can vanish or reshape without warning.

- `setup-ts-deep-modules`: prove the rules bite, do not just document them.
- `git-guardrails-claude-code`: study only; `docs/reference/branching-model.md` forbids running
  its setup here.
