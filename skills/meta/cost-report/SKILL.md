---
description: "Reports spend history per day, model and agent type from the cost-tracker log. Use when asked what sessions or subagents cost; not for live /usage."
name: cost-report
argument-hint: "[csv]"
model: inherit
effort: low
---

# Cost Report

Print the spend summary the `stop:cost-tracker` hook accumulates in
`~/.local/share/kbg/metrics/costs.jsonl`: every session on this machine, all projects, subagent
spend split out by agent type. Native `/usage` (`/cost`) covers only the live session.

## Run

One Bash call. The script reads, dedups and prints; do not open the log or add rows by hand.

```bash
node "${CLAUDE_SKILL_DIR}/scripts/cost-report-dedup.js"
```

`/cost-report csv` prints the last 100 raw rows instead. `MH_COSTS_FILE=<path>` points at another
log; use it only when the user or task names one.

A missing log prints `Cost tracker not set up` and exits 0. Relay that line and say the log fills
after the first session ends with the hook enabled. Never invent numbers. If `node` is missing,
say so; there is no other runtime.

## Read back

Quote the script's numbers as printed. Add only what a reader needs:

- **Whole machine, not this project.** The report never groups by project; compare trends over days.
- **`warning:` lines mean unknown, not zero.** Those sessions had only `jq_failed` rows and are
  left out of every total; say their spend is unknown.
- **`note:` lines first.** Rows before 2026-09-04 summed tokens per transcript line and run about
  2.4x high; a short run after that reads about 39% low on output. A total mixing eras is a
  ceiling, not a bill. Say which note applies before quoting `total`.
- **`(rate unverified)` means guessed** (priced at the Sonnet rate). Rank those by `tok`, not dollars.
- **Non-Claude models are history** (proxy models only appear before 2026-08-07).
- **Subagent spend starts 2026-08-07.** A difference across that date is a schema change.
- **Codex invocations are counts**, never dollars; the section is absent until `codex:*` ran.
- **`ledger cross-check:` compares, it does not replace.** Quote `total`. The gap is spend with no
  transcript line. `no ledger data` means mh's hooks module was not running, not zero spend;
  `module loaded: N of M sessions` is its load rate.
- **Handoff cost** (2026-09-20+ rows): median/p90 tokens main spends reading each subagent return,
  plus returns per orchestrator turn. Omitted when no row carries it.

Never re-estimate prices from raw tokens; the rate table lives in `hooks/stop/cost-tracker.sh`.

## Data model and dedup rule

Schema and legacy eras: `references/data-model.md`. The rule that must not regress: per session,
keep the latest row per (`session_id`, `stream`, `model`, `agent_type`) and sum across keys; a row
with no `stream` counts as `orchestrator`. Run `tests/skills/test-cost-report.sh` after any change
to the script.
