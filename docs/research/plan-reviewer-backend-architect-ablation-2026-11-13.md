# plan-reviewer and backend-architect against a plain prompt: ablation runs, 2026-11-13

> **Status:** a record of measurements from one cloud session, the follow-up to
> `review-agent-ablation-2026-11-12.md`. The raw result files stayed in the session scratchpad;
> the numbers below were read from them. The script beside this file rebuilds the cases from `develop` at `c5995ee2`, except
> that the three plan texts it reads were scratchpad files. All three are kept beside this file
> with a status note added on top: version 1 as `unattended-agents-human-out-proposal-2026-11-12.md`,
> versions 3 and 4 as the `unattended-jail-*-proposal-2026-11-12.md` files, those two with later
> revisions appended. Every limit under "Limits"
> applies to every number here.

## Question

Does naming `mh:plan-reviewer` or `mh:backend-architect` find more than the same request written
as a plain prompt, on the model the two agents are pinned to?

## Method

`claude plugin eval` on a throwaway copy of the plugin at `develop` (`c5995ee2`), with
`defaultEnabled` set to `true` in the copy only; `--scaffold --trust-plugin --no-publish
--ablation none`, three runs per case, `--model claude-opus-5-5` (both agents pin `opus`),
`--judge-model claude-sonnet-5-5`. The agents kept their shipped frontmatter.

- **agent**: the prompt names the agent and asks for its report verbatim.
- **plain**: the same task with no agent named. Plugin on in both; there was no plugin-off arm.

### plan-reviewer: three real plans

The plans are three designs written earlier in the same session for letting unattended runs work
on this repository, each in the form it had before any attack: version 1 (the human fully out of
the loop), version 3 (a jail plus an owner-side intake of a git bundle) and version 4 (a jail
plus a deploy key that can write only `agent/**`). Each had gone through an `mh:attack-proposal`
run whose attackers confirmed many breaks. For each plan, eight of those breaks were picked as
the ground truth, one LLM grader per break, so a run scores 0 to 8. The model saw `plan.md` and
the repository at `d0604dbf`, a commit from before any of the plans was committed, without
`CLAUDE.md`, `AGENTS.md`, `.claude/` and `.claude-plugin/`.

### backend-architect: four real pull requests and four fixtures

This repository is not a backend service. The real cases are four merged pull requests whose
later-fixed bug is a race, a failure-handling gap or a data-integrity fault (#453, #368, #965,
#752), with the task "review the design of this pull request for races, failure handling and
data integrity". The fixtures are the repository's own four planted `backend-architect` eval
cases, with their own substance grader; the earlier run got no data from them because the
runner refused the cases' Bash grant, which was removed here.

## Results: plan-reviewer

Breaks found, summed over three runs (24 possible per plan):

| plan | agent | plain |
|---|---|---|
| version 1 | 20 | 15 |
| version 3 | 14 | 13 |
| version 4 | 16 | 14 |
| **total of 72** | **50** | **42** |

Per break, runs of 3 that found it (agent / plain):

| version 1 | | version 3 | | version 4 | |
|---|---|---|---|---|---|
| author posts its own verdict | 3 / 3 | fsck claim on a bundle | 3 / 2 | ordinary fetch pulls `agent/*` | 3 / 1 |
| author posts its own status | 3 / 3 | judge-path list incomplete | 3 / 3 | hooks run at checkout | 3 / 3 |
| deleting a listed file locks commits | 3 / 3 | API key leaves the jail | 3 / 3 | freeze accepts any commit id | 3 / 3 |
| pass cache can be forged | 3 / 2 | size cap does not bound work | 3 / 3 | mounted agent socket | 3 / 3 |
| gates can be switched off | 3 / 2 | code runs as owner after push | 1 / 2 | github.com hides part of a diff | 2 / 3 |
| ask turned into deny blocks work | 3 / 1 | file name read as a git option | 1 / 0 | outsider posts the verdict | 1 / 1 |
| PR replaces its own judge | 1 / 0 | tag shadows the base | 0 / 0 | branch names break the fetch | 1 / 0 |
| a script goes around text gates | 1 / 1 | merge base hides a change | 0 / 0 | merge base hides a change | 0 / 0 |

Cost: agent 17.62 USD for nine runs plus 1.36 USD for two runs a container restart cut off
(rerun, not counted above); plain 9.35 USD.

## Results: backend-architect

Runs of 3 that found the later-fixed bug:

| case | agent | plain |
|---|---|---|
| #453 stale ancestry check, base branch unchecked | 3 | 3 |
| #965 rollback only on `OSError` | 3 | 3 |
| #368 non-finite ledger value counted as zero | 0 | 2 |
| #752 relative miss-log path refuses the merge | 0 | 0 |
| **real pull requests, of 12** | **6** | **8** |
| four planted fixtures, of 12 | 12 | 12 |

Cost: real pull requests, agent 8.56 USD and plain 6.03 USD; fixtures, agent 4.44 USD and plain
1.67 USD. Whole measurement: 49.56 USD with the smoke test.

## What the runs support

- **plan-reviewer found more of the confirmed breaks than a plain prompt** (50 against 42 of 72),
  at about twice the cost. It led on all three plans, but versions 3 and 4 (14 against 13, 16
  against 14) are within the noise of three runs; most of the gap is version 1 (20 against 15).
  The earlier report counted 18 against 16 of 33 as "not measurably more often", and neither
  report says what gap counts, so this is a lead worth a rerun, not a settled difference. The
  two series also differ in setup: this one runs on the agents' opus pin and its two prompts ask
  for different output.
- **Neither found the breaks the attackers had found by running code**: a tag that shadows the
  base, a merge base that hides a change, and (once in six runs) a file name read as a git
  option. Those breaks came from building a hostile input and executing it, which a plan review does not do (an untested guess, not a measured cause).
- **backend-architect was not ahead**: equal on its own fixtures, which are at the ceiling, and
  behind on the real pull requests (6 against 8 of 12), where the difference is one case (#368).
- Even the better condition missed about a third of the chosen breaks on the plans.

## Limits

- Three plans, all written by the session that ran the measurement, on one topic; the eight
  breaks per plan were picked by that session from the attackers' lists, and the graders were
  written by it.
- Each plan carried its own list of unverified facts, which points at some of the breaks. Both
  conditions saw the same text.
- Three runs per case. On the real pull requests one case decides the difference.
- The pull requests were chosen to resemble backend-architect's remit; none is a backend system.
- A break counts only when the judge matched it to the chosen wording; a review that found other
  real problems gets no credit for them.
- No plugin-off arm, no second model, no rerun of any eval in the repository.
- The agent condition's main session sometimes checked or summarised the agent's report instead
  of returning it verbatim; the grader read whatever the final message held.

## Files

- `plan-reviewer-backend-architect-ablation-2026-11-13.build-cases.py`: builds all 22 cases
  (three plans, four pull requests and four fixtures, each as agent and plain) with the graders.
  Its fourth argument is a directory holding the three plan files under their scratchpad names
  (`attack-proposal-human-out-of-loop.md`, `attack-proposal-option-a-no-write-access.md`,
  `attack-proposal-v4-jail-with-branch-key.md`), each as it was measured: the kept files minus
  their status note and, for versions 3 and 4, minus everything from `## Revision 1` on.
