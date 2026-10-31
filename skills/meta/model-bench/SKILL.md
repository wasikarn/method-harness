---
name: model-bench
description: "Compares two models' scored eval performance on the same case set via claude plugin eval --model, reusing existing graders. Use when choosing between models."
argument-hint: "<model-a>[@effort] <model-b>[@effort] [-- <claude plugin eval args>]"
disable-model-invocation: true
disable-model-invocation-reason: launches paid claude plugin eval runs — the user decides when to spend judge-token cost, not the model
model: inherit
effort: low
---

# Model Bench

Run this repo's eval suite once per subject model and diff the scores. It reuses the existing
graders and judge panel under `evals/`; it adds only a labeled side-by-side of two
`claude plugin eval` runs. Invoked as `/mh:model-bench` only, because it spends judge-token cost.

## Run

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/model-bench.sh" <model-a>[@effort] <model-b>[@effort] [-- <claude plugin eval args>]
```

Flags after `--` pass through to both runs (`--tag`, `--case`, `--scaffold`, `--allow-tools`, …).
Unless already passed, the wrapper adds:

- `--ablation none`: the default `with-without` doubles cost and can compare a disabled-plugin
  baseline instead of the models.
- `--threshold 0`: avoids the CLI's exit 1 on a normal run (exit 1/2 still proceed to the diff).
- `--max-cost-usd 5` per arm; pass your own to override.

It also flips `defaultEnabled` in `.claude-plugin/plugin.json` for the run and always restores it:
eval sandboxes load no user settings, so `defaultEnabled: false` would silently score a
no-plugin fallback.

Diff two finished runs without spending anything:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/model-bench.sh" --diff-only \
  --label-a <name> --label-b <name> \
  <result-a>/aggregate-result.json <result-b>/aggregate-result.json
```

## Arm syntax: `<model>[@effort]`

`model@effort` sets `CLAUDE_CODE_EFFORT_LEVEL=<effort>` for that arm's eval call only; a bare model
inherits the shell's value (usually unset). The CLI's `--effort` flag never reaches the eval child,
so the wrapper never uses it. `effort` is one of `low|medium|high|xhigh|max`; a bare `@`, `model@`,
`@effort` or a second `@` is a usage error before any `claude` call. The full arm string is the
report label, and each arm's output dir gets an `arm-meta.txt` (arm spec, command,
`claude --version`, timestamp).

## Scope caveats

- **Agent-dispatch cases.** A case whose `prompt.md` dispatches a subagent (`subagent_type:`, or a
  `graders/agent-fired.md`) runs that agent at its frontmatter-pinned model regardless of
  `--model`, except that a same-family arm moves a family-alias pin (`model: opus` follows an Opus
  arm). Whether `--model` reaches subagent dispatch in the sandbox is unverified. The report
  prints how many compared cases are agent-dispatch. `CLAUDE_CODE_EFFORT_LEVEL` outranks
  frontmatter `effort:`, so an `@effort` arm should reach dispatched agents too; also unprobed.
- **Safety-classifier fallback.** Arms on Fable, Opus 5.5, Opus 5 or the `opus`/`fable`/`best`/
  `default` aliases can be scored on the wrong model: a flagged request re-runs on Opus 4.8 or
  Opus 5 (on an Opus 5 arm a biology flag ends in a refusal). Eval runs ignore the user's
  `switchModelsOnFlag`, and `aggregate-result.json` records no model. The report prints a caveat
  for such an arm.
- **How to verify** any claim about what a child resolved (model, effort): re-run the case with
  `--keep-temp` and read the child's own `config/projects/**/*.jsonl` transcript, whose assistant
  turns record `model` and `effort`. Never the outer `--debug-file`, which shows only the parent.

## Reading the report

- **Hard-fail, no comparison:** either side has a `suite.plugins[].problem` (plugin didn't load) or
  `partial: true` (a ceiling cut the run short, so its case set differs).
- **WARN, still compared:** judge model, case filter, ablation mode, Claude Code version or plugin
  version differ between sides, or an arm's model family matches its own judge's family. Read the
  warning before trusting the delta. A judge-model WARN ending in `expected:` means one side ran
  only cases `evals/judge-models.tsv` gives their own judge (GH #510), so the mismatch is intended.
- **Not comparable:** cases present on only one side (usually different `--tag`/`--case` filters).

Never re-derive scores by hand from the JSON. `aggregate-result.json` never records the model, so
the printed label is the only record: always pass real model names.
