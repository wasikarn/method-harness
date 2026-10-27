# method-harness

A Claude Code plugin (`mh@wasikarn`) that composes `mattpocock-skills` instead of duplicating
it — checked first, before any native surface gets built. Beyond that, it adds only what native
Claude Code and the plugins it sits next to (`ponytail`, `diagram-design`, `qmd`) can't already
do: deny/ask gates on PreToolUse plus a verdict-check gate on SubagentStop/SubagentHandback, a 4 KB methodology injected at session start, and a small set of skills and
agents that earned their place.

## How it works

Three ideas hold it up; everything else is a consequence. (1) **Deny the irrecoverable set
computationally, advise on the rest**: a short PreToolUse deny list is the only place a rule is
a guarantee; every other rule is honest about being advice. (2) **The maker never grades its
own work**: a builder that touched more than one file gets a fresh-context validator, reviewer
agents are read-only and return findings, not a verdict by fiat, and the audit checks and review
agents are themselves proven against planted-defect fixtures. (3) **Score, not feel**: a
decision the triad flags carries criteria, weights, a number, and a confidence; insufficient
data blocks on the operator instead of a guessed score. The model never starts work on its
own. Detail and the full deny table: `docs/reference/operating-model.md`.

## Install

```text
/plugin marketplace add wasikarn/method-harness
/plugin install mh@wasikarn
claude plugin enable mh@wasikarn                 # from a terminal

# Required: matt-pocock's skills as their own plugin (routed by name, not bundled)
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock

# Restart Claude Code, then once per project you want the harness active in:
/mattpocock-skills:setup-matt-pocock-skills

/mh:cost-report                                  # smoke test; skills are namespaced /mh:<name>
claude plugin list                               # both plugins "enabled"
```

The plugin ships `defaultEnabled: false`; add `"mh@wasikarn": true` to `settings.json` if
`enable` did not. Same-version edits never reach the cache — bump `plugin.json` before
`claude plugin update`. Uninstall: `/plugin uninstall mh@wasikarn`.

## The gates (`hooks/hooks.json`)

One clause per gate; full scope and exceptions: `docs/reference/operating-model.md` §1.

| gate | effect |
|---|---|
| `gate:bash:irrecoverable` | denies irrecoverable commands (`rm -rf`, `push --force`, `reset --hard`, `--no-verify`, and more) |
| `gate:bash:subagent-git-guard` | denies `git stash`/`reset`/`clean` from a dispatched subagent |
| `gate:agent:subagent-spawn-guard` | denies a subagent spawning its own reviewer/validator |
| `gate:task:complete-separation` | denies a subagent marking its own task complete |
| `gate:write:test-integrity` | asks before a write that weakens a test |
| `gate:write:config-guard` | asks before a write to Claude Code settings `hooks`/`enabledPlugins` |
| `gate:write:secret-scan` | asks when a Write/Edit adds a live-credential-shaped token |
| `gate:skill:codex-setup-guard` | asks before a model-invoked `/codex:setup --enable-review-gate` |
| `gate:tool:routine-trigger-guard` | asks before `RemoteTrigger` creates, modifies, or fires a Routine (ADR 0004) |
| `gate:agent:subagent-verdict-check` | `SubagentStop` (plus a `SubagentHandback` twin): re-prompts once on a vacuous or self-contradictory Rule 13 verdict |

Each PreToolUse gate is its own entry with an 8 s timeout (the SubagentStop entry has the same
timeout). Claude Code runs matching hooks in parallel and merges deny > ask > allow (verified
empirically 2026-09-05); a timed-out gate does not block.

## What it injects

`docs/METHODOLOGY.md` (under 4 KB) at SessionStart: the decision-sizing triad, interrogate the
claim, bug fix = failing test first, context economy and delegation (10 agents per wave, a fresh
validator for a dispatched builder's multi-file work, `NEEDS-DECISION` instead of guessing),
score not feel. `git-hooks/pre-commit` refuses a `docs/METHODOLOGY.md` over 4096 bytes.

## What it ships

- **Skills (15):** `mh:harness-audit` (structural checks), `mh:memory-lint`, `mh:cost-report`,
  `mh:gate-report`, `mh:learn`, `mh:model-bench`, `mh:compliance-audit`, `mh:deep-audit`,
  `mh:idea-audit`, `mh:ideate`, `mh:post-mortem`, `mh:tech-humanize`, `mh:code-architect`, `mh:backend-architect`, `mh:requirement-analyst`. `ste-lint` exists in the repo
  and is tested, but `.claude-plugin/plugin.json`'s skills list deliberately excludes it.
- **Agents (7):** blind-spot-hunter, ideate-critic,
  performance-optimizer, plan-reviewer, silent-failure-hunter,
  test-gap-analyzer, type-design-analyzer (the last two adapted from Anthropic's
  `pr-review-toolkit`, Apache-2.0; three of its other agents duplicate native `/code-review`,
  `/simplify`, and `mh:silent-failure-hunter`, and `comment-analyzer` was skipped as low value here). Generic TS review and security review go to
  `mattpocock-skills:code-review` and native `/security-review` instead — reviewers here are
  read-only and never grant `Agent`.
- **Evals:** `evals/` holds cases in `claude plugin eval`'s native layout: a planted case and a
  clean control for each of the five review agents and for `requirement-analyst`, `harness-audit`, `memory-lint`, `deep-audit`,
  `post-mortem`, and `cost-report`; five for `tech-humanize`; a run and an abort case for `ideate`.
  Recompute the count with `find evals -mindepth 1 -maxdepth 1 -type d ! -name results | wc -l`
  rather than trust a stale literal here. `tests/evals/test-eval-cases.sh` keeps them loadable
  while the runner is early-access gated (`evals/README.md`). No CI wiring — each run is a paid
  API call and this repo has no `ANTHROPIC_API_KEY` secret — so `scripts/eval-changed.sh` is the
  local substitute: run it after editing an agent/skill file and it prints the `claude plugin
  eval` command(s) for just the tags you touched (`--run` to execute instead of print).
- **Stop hooks:** `cost-tracker.sh` (per-session token cost to `~/.local/share/kbg/metrics/costs.jsonl`),
  `memory-audit-commit.sh` (commits a git-backed memory store, opt-in).
- **Hooks module:** `hooks/mod/cost-ledger.ts` records Claude Code's own cost ledger per turn so
  `/mh:cost-report` can cross-check its transcript total (CLI 2.1.287+; observer only, no gate) —
  `docs/reference/cost-ledger-module.md`.
- **Optional pairing:** `codex@openai-codex`, installed separately and routed to by name for a
  second opinion from a different model family — see below.
- **Fragments pointer capture:** invoking upstream's `writing-fragments` skill (in-progress,
  not in the mattpocock-skills plugin's skills list) and then writing to the chosen file records
  a path pointer (never the content) at `$HOME/.claude/state/mh-fragments/`,
  surfaced at the start of a later session. No mute command — delete the record's JSON file by
  hand to forget it. `docs/adr/0003-writing-fragments-pointer-capture.md`.

## Architecture: the 6-layer harness

| layer | where it lives in mh |
|---|---|
| 1 Task contract | `docs/reference/spawn-brief.md` + the `NEEDS-DECISION` sentinel |
| 2 Context compiler | `docs/METHODOLOGY.md` (4 KB map, size gated in pre-commit) + `CLAUDE.md` |
| 3 Tool gateway | `hooks/hooks.json` PreToolUse entries, one per gate script in `hooks/gates/` (native deny > ask > allow; a gate timeout = allow) |
| 4 Durable state | native auto-memory owns it; mh adds `skills/meta/memory-lint` + `costs.jsonl` |
| 5 Evidence gate | `scripts/run-gauntlet.sh` + `skills/meta/harness-audit` + gates `test-integrity` and `task-complete-separation` (maker never grades its own work) |
| 6 Trace + recovery | Claude Code's own transcript is the run trace (tool calls, context loaded, changes made) — mh doesn't duplicate it. `hooks/stop/cost-tracker.sh` adds cost/token accounting on top; `skills/workflow/post-mortem` is the recovery loop, classifying each fix into the article's own four failure classes |

Source: "Harness Engineering: Build a Reliable AI Agent in 6 Layers" (2026-08-30).

## Optional: pairing with Codex

`codex@openai-codex` (Apache-2.0) pairs as a second, independent coding agent — a different
model family, routed to by name, never wrapped or orchestrated. Install separately
(`/plugin marketplace add openai/codex-plugin-cc`, `/plugin install codex@openai-codex`,
`/codex:setup`); mh works unchanged without it. Routing, the gate gap, and the `AGENTS.md`
pointer: `docs/reference/codex-integration-map.md`.

## Development

```bash
bash skills/meta/harness-audit/scripts/audit.sh   # the real structural gate
bash scripts/run-gauntlet.sh                       # validate + lint + every test under tests/
claude plugin validate . --strict                  # manifest shape only
git config core.hooksPath git-hooks   # relative path; pre-commit = fast gate, pre-push = gauntlet
```

Repo map and gotchas: `CLAUDE.md`. Design: `docs/reference/operating-model.md`. Frozen history:
`docs/research/`, `docs/post-mortems/`, `docs/plans/`. Pre-rebuild tree: git tag
`pre-rebuild-v0.68.673`.

## Attribution

Built on [mattpocock/skills](https://github.com/mattpocock/skills) (MIT), installed as its own
plugin and routed to by name. Mental-model catalog names from
[TJBoudreaux/cc-thinking-skills](https://github.com/TJBoudreaux/cc-thinking-skills) (MIT),
pointing upstream for write-ups. Earlier versions also adapted material from
[affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code),
[JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman),
[ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd), and
[thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) (all MIT/Apache-2.0); see the
`pre-rebuild-v0.68.673` tag for what was kept from each.

## License

MIT. See [`LICENSE`](LICENSE).
