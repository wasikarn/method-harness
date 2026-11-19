---
status: deprecated
---

> Deprecated 2026-11-13: mh no longer ships any Codex surface. The gate this record describes
> (`gate:skill:codex-setup-guard`), the quota sensors and the integration map were removed.

# Gate `codex:setup`'s review-gate toggle; leave `codex:rescue` ungated

Two of the eight `/codex:*` commands ship without `disable-model-invocation: true`:
`codex:setup` and `codex:rescue`. Both are reachable without the operator typing anything —
`codex:rescue` is also a full Agent-tool `subagent_type`. mh adds an `ask`-tier PreToolUse
gate (matcher `Skill`, firing on `tool_input.skill == "codex:setup"` with
`tool_input.args` containing `--enable-review-gate`) so the pairing's "review gate is
forbidden" constraint is a guarantee, not prose. `codex:rescue` — the surface that actually
writes code outside mh's gates — stays ungated.

The asymmetry is precedent, not risk-ranking. The setup gate reuses `gate:write:config-guard`'s
existing shape: a tool matcher plus a literal flag. Gating an Agent-tool dispatch by
`subagent_type` has no precedent in this plugin and is real new hook engineering, deferred
rather than accepted as safe. See the (since-removed) integration map's gate-gap section
for the vendor-agnostic-floor fallback while this gap stands.

## Considered options

- **Gate both.** Rejected: no existing pattern gates an Agent-tool dispatch; building one
  alongside the setup gate conflates a cheap pattern-reuse with unscoped new design work.
- **Gate neither, document-only.** Rejected for `codex:setup`: the flag match is a one-line,
  zero-ambiguity trigger — cheaper to gate than to leave as a WARN a human has to notice
  after the fact.

## Update (GH #151, 2026-09-07)

`gate:agent:subagent-spawn-guard` ships as a blanket deny on every subagent-initiated
Agent-tool call, `codex:codex-rescue` included — but it keys on the caller (`agent_id`
presence), never on `subagent_type`, so it is not the "gate an Agent-tool dispatch by
`subagent_type`" design this ADR declined above. That design question stays open; this ADR's
decision is unchanged. Main-session dispatch of `/codex:rescue` — the normal path — is
unaffected; only a subagent attempting the same dispatch is newly denied, as a side effect of
the general rule, not a codex-specific gate riding on this trial.
