# Measurement coverage status

The lazy version of the retired `harness-coverage` mechanism (deleted alongside
`hooks/session/skill-usage-telemetry.sh` in `a1055f64`, 2026-09-05) — a short static
list for the handful of measurement-dependent gates that keep getting found and lost
again, not a rebuild of its full 12-cell grid. Update this file whenever one of these
decisions changes; `skills/meta/harness-audit/scripts/checks/76-measurement-coverage-status-freshness.sh`
checks the file exists and still names all three rows, nothing deeper.

Status values: **populated** (the mechanism runs and a consumer reads its output),
**stale** (the mechanism runs but nothing reads it, or the doc describing it is out
of date), **coverage_hole** (no mechanism exists, by a documented decision — not an
oversight).

| decision | doc | expected mechanism | current status |
|---|---|---|---|
| G1/H8: restore handoff-cost `verify_tokens` (harness gap-audit, 2026-09-20; user confirmed revert) | `skills/meta/cost-report/references/data-model.md`'s `verify_tokens` section | `hooks/stop/cost-tracker.sh`'s `build_verify_map()` writes `returns`/`verify_tokens`/`verify_cache_read`/`verify_per_return` to `costs.jsonl`; `skills/meta/cost-report/scripts/cost-report-dedup.js`'s "Handoff cost" section reads them | **populated** (restored `357262b0`, 2026-09-20) |
| H9: restore skill-usage telemetry (harness gap-audit, 2026-09-20; user confirmed restore) | this file; `hooks/hook-registry.json`'s `session:skill-usage-telemetry` entry | `hooks/session/skill-usage-telemetry.sh` appends one row per skill invocation to `~/.local/share/kbg/metrics/skill-usage.jsonl`: PostToolUse(Skill) for a model call (`source: "tool"`, short names mapped to the namespaced form when one installed plugin ships them) and UserPromptExpansion for a user-typed `/skill` (`source: "typed"`, `session:skill-usage-telemetry-typed`; GH #330, rows before it are tool-only and carry no `source`); feeds the future matt-skill vs harness-skill overlap cull (#90/T11) | **populated** (restored `5cfb963b`, 2026-09-20) |
| `[role:]` tag: NOT restored alongside G1/H8 (harness gap-audit M14, 2026-09-20 — deliberate, not an oversight) | `docs/research/jev-adoption-revisit-2026-09-20.md`; `skills/meta/cost-report/references/data-model.md`'s restore-note | would have been a `role` field (`builder\|validator\|fixer\|re-validator\|research\|other`) on subagent cost rows, read from `docs/reference/spawn-brief.md`'s `[role: …]` tag, grouped in the Handoff cost report | **coverage_hole** (deliberately excluded; both fields were deleted together in `2cac98c8`, 2026-09-05, but only `verify_tokens` was restored — re-adding `role` needs its own separate decision, not bundled into this one) |
| Validator outcome per Rule 13 verdict (GH #994, C1 of the quality plan; does not touch the `role` decision above) | `hooks/gates/subagent-verdict-gate.py`, `hooks/gates/_journal.py`'s `journal_outcome`, `tests/hooks/test-validator-outcome-log.sh` | `~/.local/share/kbg/metrics/validator-outcomes.jsonl` (override `MH_VALIDATOR_OUTCOMES_PATH`): one row per single-verdict return, allow path included, counts and booleans only (`pass`, `findings`, `checked`, `scope_ok`, `unexpected`, `flaws`, `denied`, `event`), never a finding's text, a command or a path; first-pass rate = share of a session's first rows with `pass` true and `denied` false | **stale** (the mechanism runs but nothing reads it yet; the 2-week review in GH #994 is the first reader, then re-score C1b and C4. Not recorded: the round number (infer from row order per session) and the task type. Read the pass rate as a hint, not proof: it records what a validator said, not whether the work was right, and it moves with easier tasks, a looser validator or briefs that make failing harder. Before calling a change a quality gain, check it against something independent: the deterministic evals or a few hand-checked tasks) |
