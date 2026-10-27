# Skill authoring conventions

Load this when writing or editing a skill. Sibling of `agent-authoring-conventions.md`.

**Core doctrine:** follow `mattpocock-skills:writing-for-agents` (installed as the
`mattpocock-skills` plugin, not vendored). Its live elements: leading words, one trigger per
branch, completion criterion plus demand, the no-op test, negation (state the target behaviour,
not the ban), and progressive disclosure across context load vs cognitive load. That last term is
matt's writing heuristic; Anthropic's "progressive disclosure" is a 3-level runtime loading
mechanism (metadata always, SKILL.md on trigger, bundled files on read). Same words, different
question; do not conflate them.

**English only in skill and agent files** (operator rule, 2026-09-07): no Thai words, trigger
phrases, or markers in any `skills/**/*.md` or `agents/*.md`; Rule 14's Thai marker is written `insufficient evidence` inside a
skill. Exception: `tech-humanize`, whose Thai content is the subject matter.

**Description cap: 25 words, third person.** This is mh's own token-budget rule (skill and agent
descriptions ride in every session's context), not matt's. Check 20 WARNs past 1536 chars; check 43
tracks the cumulative listing budget; check 05 WARNs when a routing-length description has no
"Use when" clause; check 77 WARNs past 25 words or on a first/second-person pronoun. "Third
person" here means no `I`/`we`/`you`-class pronoun (check 77's actual test) — a bare imperative
clause like "Use when …" is not a violation and is what check 05 requires.

**No-op test, the backstop for every size-driven trim:** delete the line; does agent behaviour
change on a real branch of the skill's own worked examples? If not, prunable regardless of char
count; if so, load-bearing regardless of char count. A structural-preservation check passing
(headings, code spans, links intact) is necessary, never sufficient.

**Evals-first authoring:** before drafting a body, run the task without the skill and write down
3 concrete requests it should handle. If Claude already clears all 3, the skill should not exist.
Then write only the instructions that close gaps the baseline run showed.

**Degrees of freedom:** match how tightly a step is specified to how expensive a wrong deviation
is. Judgment calls get criteria and several valid approaches; semi-structured work gets
parameterized pseudocode; fragile or destructive steps get an exact script, no deviation.

**Citing surfaces:** an mh skill is `mh:<name>`, a matt skill `mattpocock-skills:<name>`. A
`disable-model-invocation: true` skill on either side is cited as the literal slash string the
user types (`/mh:<name>`), never "invoke X now": the model cannot call it, and a "go" in chat
does not lift that.

**`model_limitation:` frontmatter (optional, mh-native):** declare it when a skill's correctness
rests on a model behaviour that could shift on upgrade. First adopter: `tech-humanize`, whose
lexical-tell catalog assumes current-gen output still carries the enumerated tells. No check
enforces re-verification; it is a human-cadence pointer.

**`disable-model-invocation-reason:` frontmatter (mh-native):** one line on why a skill is
user-only, next to `disable-model-invocation: true`. Claude Code ignores both mh-native keys.
Check 82 allows only them and Claude Code's documented fields, because Claude Code drops an
unknown key without an error, so a typo such as `disable-model-invocaton` would silently make a
user-only skill model-invocable. A near-miss of a permission or invocation field is CRIT; any other
unknown key, such as a new Claude Code field, is a WARN until check 82's list learns it.

**Explicit `model:` + `effort:` on every entrypoint** (check 54): skills use `model: inherit`
(a concrete pin on a main-thread skill switches the session model for the rest of the turn).
Effort tiers: low = script wrapper or display, medium = deterministic tooling plus bounded
interpretation, high = normal judgment, xhigh = surfaces whose own procedure contains an
independent re-check step, or an adversarial second-pass agent. A skill an agent preloads
carries the same effort as its host. `skills/*/*/references/*.md` fragments stay unstamped.
Official Claude Code also accepts `effort: max` in frontmatter (sub-agents reference); the
fleet assigns it no tier because it means unbounded token spend on a shipped agent, so check 54
WARNs on it. A session `/effort max` or `--effort max` doesn't reach a surface that pins
`effort:` (frontmatter overrides the session level); only `CLAUDE_CODE_EFFORT_LEVEL=max` does,
and it lifts every surface in that session, `low` ones included.

**Reference files** (Anthropic Agent Skills best practices): one level deep from SKILL.md, and MCP tools named `ServerName:tool_name`
(`qmd:query`, not `query`). A reference file must not carry `description:` frontmatter, or
Claude Code loads it as its own skill (check 42). A reference file over 100 lines carries a `## Contents` heading in
its first 30 lines, because a nested reference may be read with `head -100` (check 81).

**Size:** keep a `SKILL.md` under 500 lines (Anthropic's cap); an agent file may carry its own trailing
`# Reference` section instead of a preload skill.
