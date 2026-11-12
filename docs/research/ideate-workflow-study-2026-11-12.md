# `ideate` as a skill, as a workflow, and bare Claude (2026-11-12)

**Date:** 2026-11-12
**Subject:** `mh:ideate` at develop `d0604dbf` (mh 1.1.615), and a workflow rewrite of it,
`ideate-workflow-study-2026-11-12.ideate-wf.js` beside this file (sha256 `619d363b...`).
**Why:** the question was whether mh's multi-agent skills should become Claude Code Workflow scripts. `ideate` was
the one tried.
**How it was run:** `claude plugin eval` with `--scaffold --ablation none --trust-plugin --keep-temp`, 5 runs per
arm per case, on four design-question cases (`dq-partner-notify`, `dq-account-restore`, `dq-payout-retry`,
`dq-product-search`). One agent that had read nothing in this repo wrote the cases; a second checked that each
fixture holds the evidence. Prompts, scaffolds and graders were hashed before the first run (sha256 `6e3ee433...`)
and not edited after. Each decision rule below was written before its arm ran. The cases, replies and traces were
kept in a session scratchpad and are not in this repo; only the workflow script is.

## 1. What to take from this

1. **Do not replace the `ideate` skill with this workflow.** It passed the rule written for it, by thin margins,
   and lost clearly to the skill on one case of four (section 5).
2. **This is not evidence about workflows in general.** The workflow differs from the skill in five ways at once
   (section 5, limits). No other mh skill was tried.
3. **`ideate` does not start on its own stated trigger.** With mh loaded and a prompt that asks to
   "Brainstorm ..." after a sentence or two of context, the skill fired in 0 of 20 runs (section 3). Its
   description says "Say 'brainstorm'". No prompt opened with the word, so an opening trigger was not tested.
4. **`ideate` does widen the option set when it runs.** A reply had 1.5 to 2.7 times as many distinct approaches
   as bare Claude's (section 5 table; 2.6 to 4.0 times in the first measurement, section 4).
5. **Bare Claude already avoids the evidenced-bad option.** 19 of 20 as adjudicated (section 2), so the outcome
   grader has no headroom on these cases for either form.
6. **Do not trust the llm judge alone on these cases.** It failed 7 replies that a reader passes (4 bare, 1
   skill, 2 workflow): the 4 bare and 2 workflow ones each recommend the acceptable option and name the
   ruled-out one only as a later step; why it failed the skill reply was not recorded. This counts
   `avoids-evidenced-cost` only: the judge also failed 3 bare replies on `commits-to-one` that the adjudicator
   passed.

## 2. Bare Claude (no plugin)

20 runs, 0.15 USD and 6 to 11 turns per run. Decisive grader `avoids-evidenced-cost`: the automated judge passed
15 of 20; a fresh adjudicator reading the replies passed 19 of 20. The one real failure recommended a 30-day grace
period on `dq-account-restore`, past the fixture's 21-day limit. `commits-to-one`: 20 of 20 as adjudicated.
Limit: the adjudicator did not read three `dq-partner-notify` replies to the end.

The pilot's rule, written before it ran: a case has headroom if bare Claude fails the decisive grader in 2 or more
of 5 runs; with 0 or 1 such cases, stop and build neither the skill arm nor the workflow. Read from the automated
judge, 2 cases had headroom; read from the adjudicator, none. The later arms went ahead on a different question,
breadth, which the pilot's plan named as outside what it measures; they are not licensed by this rule.

## 3. mh loaded, skill not named

Same frozen prompts. `mh:ideate` fired in 0 of 20 runs (no `Skill` or `Agent` call in any trace; on the five
`dq-partner-notify` runs the skill was confirmed listed and the doctrine injected, the other cases were not checked
for that). 0.23 USD per run. Automated judge 16 of 20; not adjudicated.

## 4. Skill named in the prompt

One sentence put in front of the unchanged question asks for `mh:ideate` by name. It fired in 20 of 20 runs with
6 `Agent` calls each: 1.22 USD and about 209 seconds per run.

Breadth was measured per case over 10 replies (5 bare, 5 skill): one agent listed every option each reply offers
as neutral one-line statements under shuffled ids; a second agent, seeing only those lines, grouped them by
underlying approach; code then counted distinct clusters per reply against a mapping kept sealed until then.

| Case | bare | skill | ratio | core only: bare / skill |
|---|---|---|---|---|
| dq-partner-notify | 5.8 | 16.6 | 2.86 | 5.8 / 12.0 |
| dq-account-restore | 5.4 | 14.2 | 2.63 | 3.0 / 6.0 |
| dq-payout-retry | 5.2 | 13.4 | 2.58 | 5.2 / 8.0 |
| dq-product-search | 4.6 | 18.6 | 4.04 | 4.4 / 12.2 |

Rule (skill mean at least 1.5 times bare and at least 2 higher): met in 4 of 4. Adjudicated outcome: skill 18 of
20, bare 19 of 20; both arms' failures are the same 21-day-limit miss.

## 5. Workflow named in the prompt

The script runs one context agent that reads the repo, five isolated frame agents in parallel, then
`mh:ideate-critic`, and returns the ideas, the critic's JSON and render instructions to the host. One sentence in
front of the unchanged question asks for it by name. One smoke run was made and excluded as planned.

- **Completed:** 20 of 20 runs called `Workflow` once, ran 7 agents, and the critic's JSON parsed.
- **Cost:** 0.97 USD and 169 seconds per run, 20.4 percent below the skill. The eval's cost figure includes the
  workflow's agents (the trace's per-model usage carries their tokens).
- **Outcome:** 20 of 20 as adjudicated (automated judge 18). No difference from the skill or bare that 5 runs can
  show; each arm had its own adjudicator.
- **`cites-evidence` (regex):** workflow fails 5 of 20, four of them on `dq-product-search`; skill fails 3 of 20.

Breadth, all 15 replies per case extracted and clustered again from scratch with a new shuffle:

| Case | bare | skill | workflow | workflow / skill | core only: bare / skill / workflow | core ratio |
|---|---|---|---|---|---|---|
| dq-partner-notify | 7.0 | 18.8 | 16.0 | 0.85 | 6.8 / 10.8 / 10.2 | 0.94 |
| dq-account-restore | 12.0 | 18.2 | 17.4 | 0.96 | 7.0 / 9.6 / 9.2 | 0.96 |
| dq-payout-retry | 8.4 | 15.8 | 13.6 | 0.86 | 6.6 / 7.4 / 8.0 | 1.08 |
| dq-product-search | 9.2 | 21.0 | 14.8 | 0.70 | 5.0 / 12.4 / 7.2 | 0.58 |

Rule written before the arm ran: ship candidate if the workflow keeps at least 0.8 of the skill's breadth in 3 of
4 cases, completes 18 of 20, and its outcome is not worse than the skill's by more than 2 runs. Met: 3 of 4, 20 of
20, not worse. On `dq-product-search` the skill reached 7 core approaches no other arm reached; the workflow 1.

Limits:

- **Five differences at once.** The workflow adds a context agent (7 agents, the skill uses 6); fixes the five
  frames where the skill's host picks them; builds the critic envelope in the script; sets the frame agents to
  `effort: medium` where the skill's frontmatter says `high`; and tells the host to check its pick against the
  context brief. Neither the cost gap nor the `dq-product-search` gap can be assigned to one of them, or to the
  workflow form.
- **Thin margins.** Two passing cases sit at 0.85 and 0.86 against a 0.80 line, and cost is 0.4 points past the 20
  percent line.
- **The instrument's grain moves.** Bare means are higher in this table than in section 4 for the same replies,
  and skill over bare went from 2.63 to 1.52 on `dq-account-restore`. Compare arms inside one table only.
- **Width is not quality.** The extra approaches include ones the replies themselves flag as traps.
- **Small and same-family.** Five runs per arm; extractor, clusterer and adjudicators are the same model family as
  the arms; one of each per case. The extractor could tell workflow replies apart by their wording; the clusterer
  saw only the neutral lines.
- **Plain prompt not tested for the workflow.** It was only ever invoked by name.
- **A diagnostic in the script is unreliable.** It compares an index into the untrimmed critic reply with the
  trimmed length, so a pure-JSON reply with leading whitespace is reported as "wrapped in other text". It still
  parses; the 20-of-20 figure is unaffected. The script is kept as measured, not fixed.

## 6. Workflow mechanics checked before the rewrite

Three probes with a throwaway plugin, each run once; their output was not kept in this repo:

- mh's gates fire inside workflow agents: `git add -A` was denied, and `git stash` was denied as a subagent action.
- Workflow agents receive `CLAUDE.md` but not the `docs/METHODOLOGY.md` that mh injects at session start.
- `agentType: 'mh:blind-spot-hunter'` resolves from a workflow and composes with `schema`.

Also seen: a plugin ships workflows from `workflows/` at its root, invoked by `name: "<plugin>:<workflow>"`;
`claude plugin eval` runs them in its sandbox with `--allow-tools Workflow`; a `tool_used: Workflow` grader works.

## 7. Eval spend

Bare 3.0 USD (plus 0.42 on runs made before `case.yaml` declared the scaffold, which had an empty workspace);
mh with the skill not named 4.7; skill named 24.3; workflow 19.4 plus 0.82 for the smoke run. About 53 USD,
not counting the extractor, clusterer and adjudicator agents or the probes.

## 8. Not done

A workflow that ports the skill as it is (6 agents, host-picked frames, `effort: high`) would separate the form
from the redesign. It needs new cases: the rule for this one forbids tuning the script and rerunning on the same
four.
