# Haiku decision calls

Pattern for a skill that needs a fast, cheap, schema-locked yes/no or pick-one decision mid-flow,
without dispatching a full adversarial-review subagent. Not wired into any skill or gate yet —
this is a reference for a future author to cite, the same role `spawn-brief.md` plays for
subagent dispatch shape. Background and the "should mh build a Jev clone" question this answers:
`docs/research/haiku-jev-decision-primitive-2026-09-18.md`.

## Two routes, one of them weaker

**Inside Claude Code (the Agent tool):** the only per-dispatch knob is `model` (`"haiku"`).
There is no `tool_choice`, `strict`, `max_tokens`, or `thinking` on an Agent call — those are
Messages API request-body fields. So a Haiku subagent gives you the cheap model plus a
prose output contract in the brief (`docs/reference/spawn-brief.md`), which is the "was told
to only answer X or Y" guarantee, not a structural one. Good enough for a low-stakes pick;
not the guarantee described below.

**Raw Messages API (a script with `ANTHROPIC_API_KEY`):** the structural guarantee. Force a
single tool call with a narrow enum `input_schema`, `strict: true`, no manual `thinking`, and a tight
`max_tokens` (a forced tool call on Haiku 5.5 starts with the tool call and has no `thinking` block,
so a tight `max_tokens` is safe). No script in this repo makes such a call today (`hooks/`, `scripts/` and `skills/`
grep clean for `api.anthropic.com`/`tool_choice`, 2026-10-21), so the first consumer also adds the API-key
path — a separate decision, not a detail.

```json
{
  "model": "claude-haiku-5-5",
  "max_tokens": 64,
  "tool_choice": {"type": "tool", "name": "answer"},
  "tools": [{
    "name": "answer",
    "strict": true,
    "input_schema": {
      "type": "object",
      "properties": {"choice": {"type": "string", "enum": ["a", "b", "c"]}},
      "required": ["choice"],
      "additionalProperties": false
    }
  }]
}
```

`additionalProperties: false` is required on every object in a strict schema, not optional
(structured-outputs "JSON Schema limitations").

`strict: true` turns on grammar-constrained sampling, which guarantees the tool `input` matches
the schema — the same class of structural guarantee Jev's `Choice`/`Noul` primitives claim, via a
different mechanism (constrained decoding on a still-autoregressive model, not a non-autoregressive
head). It's faster and cheaper than an open-ended call on the same task, for the ordinary reason a
short forced answer costs less than a free-form one — not because it skips attending over the
input context.

## Three hard caveats

- **No manual extended thinking.** `thinking: {type: "enabled", budget_tokens: N}` returns 400 on
  Haiku 5.5 (and fails with a forced `tool_choice` on older models). Leave `thinking` unset: adaptive
  thinking is on by default (effort `medium`) and does not block forced tool use on Haiku 5.5, and the
  migration guide says a forced tool call returns the call with no `thinking` block (checked 2026-10-09).
- **No `temperature: 0`.** Haiku 5.5 accepts only `temperature: 1` and `top_p: 0.99` (the default); any
  other value, any `top_k`, or `temperature` together with `top_p` returns 400. Determinism for a
  decision call has to come from the forced enum tool and the prompt, not from sampling settings.
- **No confidence field.** The Messages API has no logprobs or token-probability field anywhere.
  A "confidence" number the model writes into its own JSON output is self-reported, not measured.
  A confidence *band* is not a manufactured number, but this decision class (cheap single calls,
  no logprobs available) still gets none — omit it or return **ข้อมูลไม่เพียงพอ**.

## When not to use this

For an adversarial audit, multi-page brief, or anything needing `findings[]`-shaped output, use
the existing `codex exec --output-schema` / Claude-fallback contract pattern instead
(`docs/reference/codex-integration-map.md`, `docs/reference/spawn-brief.md`) — this pattern is for
a single cheap in-flow decision, not a review pass.

## Sources

- [Define tools — Forcing tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools#forcing-tool-use) — `tool_choice` types, manual-extended-thinking restriction
- [Strict tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use) — grammar-constrained sampling guarantee
- [Structured outputs — JSON Schema limitations](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) — `additionalProperties` must be `false` for objects
- [Subagents](https://code.claude.com/docs/en/sub-agents) — `model` is the only per-invocation Agent parameter that shapes the request (the others pick the agent and carry the prompt)
- [Claude Haiku 5.5 migration guide](https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide) — thinking, sampling and prefill changes; forced `tool_choice` returns no `thinking` block
- [Claude Haiku 5.5 model page](https://platform.claude.com/docs/en/models/haiku-5-5/overview) — model ID `claude-haiku-5-5` (no dated id), adaptive thinking, default effort `medium`, 1M context
- [Messages API reference](https://platform.claude.com/docs/en/api/messages) — no logprobs/token-probability field exists
- [Pricing](https://platform.claude.com/docs/en/about-claude/pricing) — Haiku 5.5 $0.10/$0.50 per MTok in/out for prompts up to 100k tokens ($0.50/$2.50 above); Haiku 4.5 is $1/$5
- `docs/research/haiku-jev-decision-primitive-2026-09-18.md` — full feasibility analysis and design options
