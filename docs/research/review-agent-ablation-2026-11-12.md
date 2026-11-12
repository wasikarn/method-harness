# Review agents against a plain prompt: ablation runs, 2026-11-12

> **Bottom line:** on real pull requests the two review agents did not find the later-fixed bug
> measurably more often than the same request as a plain prompt (18 against 16 of 33 runs on
> sonnet, 16 against 16 of 21 on opus), at roughly three times the cost per case; the model
> mattered more than the condition. The repository's own fixtures are at the ceiling and separate
> nothing, except `requirement-analyst-clean`, where the agent and the short sentence passed and
> the plain prompt did not, with the plugin on or off.
>
> **Status:** a record of measurements from one cloud session. The raw result files were in the
> session scratchpad and are not kept, so the numbers below, read from them at the time, cannot be
> re-checked. The two scripts beside this file build the cases (see "Files" for what they need).
> Every limit listed under "Limits" applies to every number here.

## Question

Does naming an mh review agent find more than the same request written as a plain prompt, on
the same model? And does having the plugin enabled change a plain prompt's result?

## Method

All runs used `claude plugin eval` on a throwaway copy of the plugin (`git archive HEAD`, with
`defaultEnabled` set to `true` in the copy only), `--scaffold --trust-plugin --no-publish`,
three runs per case, one LLM grader per case.

Conditions:

- **agent**: the prompt names the agent (`subagent_type: "mh:<agent>"`), plugin on.
- **plain**: the same task with the agent's name removed, plugin on.
- **bare**: the plain prompt in the eval's no-plugin arm (`--ablation with-without`).
- **short**: the plain prompt plus one fixed sentence, the same for every case: "Report only
  problems that are real in the material as written. If there are none, say so plainly and stop:
  do not add speculative concerns, optional suggestions or open questions."

The repository's own `contract.md` graders check the agent's report format, which a plain
prompt cannot match, so each case got one substance-only grader written for these runs (a
planted defect found, or a clean verdict correct). Those criteria are in the two builder
scripts.

From run 2 on, agent models were set to `inherit` in the copy, so every condition ran on the
model named for the run. This differs from the shipped agents, some of which pin `opus`. Run 1 is
the exception: its agents kept their pins.

## Run 1: the repository's own fixtures, first criteria (sonnet session, haiku judge)

Passes of 3. The criteria in this run marked down any extra observation, and the agents still
had their pinned models, so read it only as the reason for run 2.

| case | agent | plain | bare |
|---|---|---|---|
| blind-spot-hunter-clean | 3 | 2 | 3 |
| blind-spot-hunter-planted | 3 | 1 | 1 |
| plan-reviewer-clean | 2 | 0 | 0 |
| plan-reviewer-planted | 3 | 2 | 3 |
| plan-reviewer-trivial-no-rollback | 3 | 0 | 0 |
| requirement-analyst-clean | 3 | 0 | 1 |
| requirement-analyst-planted | 3 | 0 | 0 |
| silent-failure-hunter-clean | 3 | 1 | 1 |
| silent-failure-hunter-planted | 2 | 1 | 0 |
| test-gap-analyzer-clean | 3 | 3 | 1 |
| test-gap-analyzer-planted | 3 | 1 | 2 |
| type-design-analyzer-clean | 3 | 0 | 0 |
| type-design-analyzer-planted | 3 | 3 | 3 |
| **total of 39** | **37** | **14** | **15** |

Four bare answers that scored 0 were read: each had found the planted defect or given the right
clean verdict, and was marked down for added notes. The four `backend-architect` cases produced
no data in any condition: the eval runner refused the Bash grant in this container ("cannot
confine it"). Cost: 8.46 USD.

## Run 2: same fixtures, substance criteria, one model (sonnet for runs and judge)

| condition | passes of 39 |
|---|---|
| agent | 39 |
| plain | 36 |
| bare | 36 |
| short | 39 |
| short, no plugin | 39 |

Every case scored 3 of 3 in every condition except `requirement-analyst-clean`, where plain and
bare scored 0 of 3: the answer called the ticket clear and then listed gaps and questions. With
the short sentence it scored 3 of 3. Cost: 8.75 USD for agent, plain and bare; 3.61 USD for
short.

These fixtures are at the ceiling for every condition, so they cannot separate the conditions.

## Run 3: real pull requests from this repository

Cases: 12 merged pull requests that shipped a bug a later pull request fixed, found by blaming
fix commits back to the merge that introduced the lines, and 4 "controls" whose added lines no
later fix commit touched. Each case gave the model the repository at the pull request's head
(without `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.claude-plugin/`) and `pr.diff`. The agent
condition dispatched `mh:blind-spot-hunter` and `mh:silent-failure-hunter` in parallel
(`silent-failure-hunter` has since been removed from `develop`). A bug case passes when the
answer names a defect its criterion in `build-pr.py` lists (one to four per case); other
findings do not lower the score. Each list holds the bug the later fix confirms, and the longer
ones hold further defects this record does not show a later fix for.

Passes of 3, sonnet for runs and judge:

| pull request, bug | agent | plain | bare | short |
|---|---|---|---|---|
| #368 non-finite ledger value counted as zero | 1 | 2 | 1 | 0 |
| #420 `--slug` path traversal | 3 | 0 | 1 | 0 |
| #453 base branch unchecked, stale ancestry check | 3 | 3 | 3 | 0 |
| #494 session window ordered by first use | 0 | 1 | 0 | 0 |
| #502 leading-zero version passes | 0 | 0 | 0 | 0 |
| #544 deny matches any mention of codex | 3 | 3 | 3 | 2 |
| #625 fence toggle, merge commits, manifest allowlist | 3 | 3 | 3 | 0 |
| #644 unvalidated retry count | 0 | 0 | 0 | 0 |
| #752 relative miss-log path refuses the merge | 0 | 0 | 0 | 0 |
| #944 `ls-tree` relative to cwd | 2 | 1 | 0 | 0 |
| #965 rollback only on `OSError` | 3 | 3 | 1 | 0 |
| **total of 33** | **18** | **16** | **12** | **2** |

#975 is left out of the totals: the plain run stopped at its cost cap before reaching it (agent
1 of 3, short 0 of 3). Cost: 45.17 USD (agent 24.20, plain and bare 14.40, short 6.57).

The same cases on opus (sonnet judge). Both groups stopped at their cost caps, so only seven
pull requests have three runs in every condition:

| pull request | agent | plain | bare |
|---|---|---|---|
| #368 | 3 | 2 | 0 |
| #420 | 3 | 2 | 3 |
| #453 | 3 | 3 | 3 |
| #494 | 1 | 3 | 3 |
| #502 | 2 | 0 | 0 |
| #544 | 3 | 3 | 3 |
| #625 | 1 | 3 | 3 |
| **total of 21** | **16** | **16** | **15** |
| same seven on sonnet | 13 | 12 | 11 |

Also on opus: #644 scored agent 0 of 2, plain 2 of 3, bare 2 of 3; #752 scored plain 0 of 3 and
bare 0 of 2 with no agent run. Cost: 94.93 USD (agent 56.84, plain and bare 38.09), which was
over the 85 USD the two caps added up to: the cap is checked before each run starts.

## The controls were not clean

On opus the four control cases scored 0 to 2 of 12 in every condition, because the answers
reported defects. Four agents then clustered the findings from the 36 opus answers and checked
each against the code at the pull request's head, running the code where they could:

| control | findings | real, in the PR's lines | not a bug | could not settle |
|---|---|---|---|---|
| #359 skill telemetry | 16 | 8 | 6 | 2 |
| #535 bash output redact | 13 | 5 | 7 | 1 |
| #746 hooksPath re-exec | 13 | 6 | 6 | 1 |
| #878 gauntlet progress | 16 | 9 | 5 | 1 (and 1 real but older) |

So the control scores in run 3 measure nothing, on either model: the criterion penalised an
answer for finding a real bug. Several of those bugs were re-run against `develop` at `d0604dbf`
and still reproduced; fixes went into pull requests #1019 and #1020.

In those four reviews the agent condition more often rated a real finding low or out of scope,
and twice rated as HIGH a finding that did not reproduce or was unchanged behaviour. The plain
condition also overstated one finding. This is a reading of four cases, not a count.

## What the runs support

- On one model, the two review agents did not find the later-fixed bug measurably more often
  than a plain prompt (18 against 16 of 33 on sonnet; 16 against 16 of 21 on opus), at about
  three times the cost per case (24.20 USD against half of the 14.40 USD that plain and bare
  shared on sonnet; the split between those two was not recorded).
- The model mattered more than the condition: opus was ahead of sonnet by 3 to 4 of 21 in each
  of agent, plain and bare (the short sentence was not run on opus).
- The conditions found different bugs (#502 only by the agents on opus; #494 and #625 mostly by
  the plain prompt on opus), so they are not interchangeable.
- The short sentence is harmful on hard input: 2 of 33. Its 39 of 39 in run 2 came from easy
  fixtures.
- Plugin on against off, with a plain prompt: 16 against 12 of 33 on sonnet, 16 against 15 of
  21 on opus. Half of the sonnet gap of 4 is one pull request (#965, 3 against 1); #368, #494
  and #944 add 1 each and #420 takes 1 away.
- Every condition missed the later-fixed bug often: on sonnet in 15 (agent), 17 (plain) and 21
  (bare) of 33 runs and in 31 of 33 with the short sentence; on opus in 5 to 6 of 21.

## Limits

- Three runs per case, and 11 scored bug cases from one repository (plus the four controls, which
  measured nothing); five of the six bash cases are in `scripts/merge-pr.sh`.
- The grading criteria were written for these runs by the same session that ran them.
- A bug case counts only the defects its criterion lists; an answer that found a different real
  bug scores 0.
- The repository is public, so a model may have seen the fix commits.
- The opus run is incomplete, and no run after run 1 used the agents' shipped model pins.
- `test-gap-analyzer`, `type-design-analyzer` and `requirement-analyst` were never run on real
  pull requests: for them there are only the ceiling fixtures of run 2, which show no measurable
  gain for the first two and a 3-run gain for `requirement-analyst` on its clean case.
- Only review agents were measured. Nothing here is about gates, skills, doctrine or
  `backend-architect`, `plan-reviewer` on real work, or `ideate-critic`.
- The findings check on the controls was done by agents; the session re-ran a subset.

## Files

- `review-agent-ablation-2026-11-12.build-variants.py`: builds the fixture variants of runs 2
  (agent, plain, short) from the repository's eval cases, with the substance criteria. Run 1's
  stricter criteria were overwritten and are not kept.
- `review-agent-ablation-2026-11-12.build-pr.py`: builds the real-pull-request cases of run 3
  from merge commits, with each case's criterion.

Both scripts need a checkout at a commit before `5b297ee1`, where the `silent-failure-hunter`
agent and its eval cases left `develop`. `build-variants.py` reads the eval cases of that
checkout and stops with `FileNotFoundError` when one is missing. `build-pr.py` takes each case's
tree from its merge commit, so it needs the full history, and copies the plugin from `HEAD`; it
refuses a `HEAD` that lacks either agent its prompts name, `blind-spot-hunter` or
`silent-failure-hunter` (before 2026-11-13 it built from such a `HEAD` without an error, and the
agent condition then named an agent the copy did not have). The commit the runs were built from
is not recorded here. Both refuse an output directory outside the temp dir, because they delete
and rebuild it.
