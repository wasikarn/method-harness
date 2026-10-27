# Review-agent and skill evals

79 cases in Claude Code's native `claude plugin eval` layout (count:
`find evals -mindepth 1 -maxdepth 1 -type d ! -name results | wc -l`; re-run rather than trust
this number, it has drifted before — see `docs/research/ai-native-sdlc-playbook-audit-2026-08-28.md`
Round 3). Twelve cover the six review
agents, one planted-defect case and one clean control per agent, the same fires/silent pairing
`tests/skills/harness-audit/known-bad/` uses for audit checks. Each case is
`prompt.md` (the ask: an agent case dispatches by `subagent_type`, a skill case invokes by `skill:`), `case.yaml` (a
`scaffold_script` that writes the fixture into the throwaway workspace), and `graders/`:

| grader | type | what it proves |
|---|---|---|
| `agent-fired.md` | `tool_used: Agent` | the session dispatched the agent instead of reviewing inline |
| `contract.md` | `regex` | the report ends in the agent's documented Output Format |
| `finding.md` / `clean.md` | `regex` | the planted defect was found at its file, or the clean control got the clean verdict |
| `criteria.md` | `llm` | the finding is the right one, sized right, with no manufactured extras |

Five for the `tech-humanize` skill (tag `tech-humanize`): three planted cases (English prose,
Thai standup, Thai UI copy), a clean human-written control that must survive lightly edited, and a file-input
case that proves the prose-only constraint (frontmatter and code block byte-identical, graded on
the file's contents). Their `skill-fired.md` is `tool_used: Skill`; their regex graders assert a
planted tell is absent (`not_contains`) or a source specific is kept (`contains`), and the loader
test proves each pattern against the scaffolded fixture.

Two for `post-mortem` (tag `post-mortem`): a complete case whose repo carries the fix commit and
regression test, graded on all 11 sections in order, no hedging, a Rule 4 failure class, and an
LLM rubric for the checklist and anchoring; and a missing-input case that withholds the
validation input and must get a question, not a draft. The skill is user-invoked
(`disable-model-invocation`), so `prompt.md` opens with `/mh:post-mortem` and `skill-loaded.md`
is a `trace` regex on the skill's own text rather than `tool_used: Skill`. Two runner facts are
undocumented and the first live run settles both: whether a slash command in `prompt.md` is
expanded, and whether `target: trace` is accepted (these are the only two graders using it).

Two for `harness-audit` (tag `harness-audit`): a planted fleet with two CRITs (skill name
mismatch, missing `tools:` grant) that the session must fix and confirm with a second run
(`audit-reran.md` is `tool_used: Bash`, min 2; file graders check the fix landed in the named
file), and a clean control that must get no edits (`no-edits.md` is `tool_used: Edit`, max 0; `max`
is this suite's first use of the key and unverified against the runner, so `fleet-unchanged.md`
proves the same thing on the file's bytes).
The scaffolded repo is its own plugin cache (`--plugin-cache .`). Bash is not granted by
default: run these with `--allow-tools Bash` (the prompt frontmatter also lists it).
Two for `ideate` (tag `ideate`): a full run on an open design problem, bounded on Agent calls
(`fanout.md`, `tool_used: Agent` min 6 max 6: 5 Diverge + 1 critic, the default path; the
opt-in host path's 8 is out of scope), required to dispatch `mh:ideate-critic`
(`critic-dispatched.md`, `tool_used: Agent` with `input_match`; `agent-fired.md` rules out the
generic fallback) and
graded on the rendered output shape (score chips, ★ pick, provocation line); the isolation
invariant and wave shape are not observable from these graders; and an abort control, a
"quick"/"canonical" question that must fail the pre-flight gate and get a direct answer with no
Agent call at all (`no-fanout.md`, max 0).

Two for `memory-lint` (tag `memory-lint`): a planted store with one repairable finding per
detector class (typo'd wikilink, stale pointer, unindexed unreachable file) that the session must
fix at the cause and confirm with a second run (`lint-reran.md` is `tool_used: Bash`, min 2; file
graders prove the link was corrected not deleted, the stale pointer removed not satisfied by a new
file, and the unindexed file indexed), and a clean control that must receive no Edit or Write (`store-unchanged.md` proves the index bytes as well).
Bash is not granted by default: run these with `--allow-tools Bash` (the prompt frontmatter lists
it too).

Two for `deep-audit` (tag `deep-audit`): the scaffold is a small git history that is the
"session" under audit. In the planted case the second commit and `NOTES.md` claim a zero-total
guard and a regression test; the commit's diff is a docstring and the suite has no zero-total
case, so the re-run is green with one test and the claim is false on the diff. The case grades
the audit's process (git-derived scope, rubric, checker dispatch, test-first fix, re-score), not
detection difficulty. The clean case makes the same claims truthfully and must come out
byte-identical. Graders check the skill and a checker agent fired, git and the test runner ran
(`tool_used: Bash` anchored on the command), the fix and its test landed in the named files, and
the report opens with the Final Verdict line. Needs `--allow-tools Bash,Edit,Write`.

The six `deep-audit-step6-*` cases (the step-6 whole-picture trigger) use the same shape: a
`scaffold.sh` builds a two-commit history, the latest commit is the session, and the prompt only
states the task. Until GH #389 the subject typed that history itself from the prompt, which also
told it the answer ("no bugs", "nothing else imports this"). Rule for every case here: a case
prompt states the task, never the expected verdict or the trigger fact. Fixture history goes in
`scaffold.sh`, never in a narrative the subject types itself. `tests/evals/test-eval-cases.sh`
fails on a narrow word list (`planted`, `rubric`, `grader`, `no bug(s)`, `accurate`, `correctly
implemented`) in a prompt body; a paraphrased tell still gets past it. Tradeoff: without the tell,
a subject that "fixes" a non-bug now fails `zero-fixes-skip`, so that case also measures false
fixes and overlaps `deep-audit-clean`. The pilot numbers in `c182ffc6` were taken with the tells
in place, so the two should-not-fire results there are not clean measurements.

Two for `cost-report` (tag `cost-report`): a planted log with a session whose two rows must
collapse to the newer one (latest row per key, then sum: $10, where a hand sum gives $15) and one
legacy-era row that makes the script print a `note:` line the read-back must carry; and a
not-set-up control with no log, which must relay the script's "Cost tracker not set up" line,
quote no dollar figure, and create no log (`no-log-created.md` is `tool_used: Bash` max 0 on a
redirect into `costs.jsonl`; Write and Edit are not granted). The prompt points the script at the
workspace log with `MH_COSTS_FILE`, since the sandbox HOME is fresh and case `env` keys must be
`EVAL_*`. Needs `--allow-tools Bash`.

Note for future suites (not skill-specific, kept from the removed `handoff` suite):
`context.scaffold_script` must be a relative path to an external `.sh` file in the case dir (e.g.
`scaffold_script: scaffold.sh`); inline YAML block content (the shape every other suite here
predated this and used) is mis-parsed as a literal path under the installed CLI and fails to load
— confirmed on `post-mortem`. See "A previously-invisible defect" below: every other suite in
this file has since been converted to the file-path form.

`code-architect` and `performance-optimizer` were agents until 2026-10-27, when they were folded
into skills after the fold-vs-keep eval below scored the folded form worse on no case. Their
cases were written for the agent form; every fire-case prompt now loads the skill via the Skill
tool (`skill: "mh:<name>"`), `dispatch-confirmed.md` checks that Skill call, and `agent-fired.md`
checks the trace has no `Unknown skill: <name>` error.

Eight for `code-architect` (tag `code-architect`).
Natural routing into this agent never fires on its own for a well-worded architecture request —
the top-level model just solves it inline, since it has the same read tools — so every fire-case
prompt explicitly instructs dispatch; that shifts what's measured from "does routing pick this
agent" to "does its process beat a generic fallback," which is what these cases actually test.
Five fire cases, each targeting one of the agent's own specific, checkable claims against a small
scaffolded fixture repo (comments that would spoon-feed the answer are deliberately absent from
the fixtures): a layered repo where the blueprint must not have the domain layer import infra
(`layer-direction`); a closest-shaped existing analog that itself violates layer direction, which
the blueprint must recognize and reject rather than copy (`disqualified-analog`); a single
concrete implementation with a request phrased to invite a speculative plugin interface
(`premature-abstraction`); a codebase with a consistent constructor-injection style the blueprint
must match (`di-style-respect`); and a requirement with a genuine two-reading fork that must be
named as a prominent callout, not silently resolved (`ambiguous-requirement`). Plus one
should-NOT-fire case: a trivial one-line rename, which must be done directly without loading
the skill or producing a full blueprint as a substitute (`trivial-no-dispatch`). Plus two chain
cases (second tag `chain`), where the blueprint is handed on to `mh:plan-reviewer`: one prompt names
the reviewer and scores the handoff's quality (`chain-plan-reviewer`), and one only asks for the
plan to be checked and scores whether a fresh-context reviewer is called unprompted
(`chain-unprompted`). These catch a folded main loop skipping the next specialist. In the
without-plugin arm, `mh:code-architect` doesn't exist — the Skill call fails with
`Unknown skill: mh:code-architect` and the model answers without it. A `tool_used: Skill` check
alone matches that failed call too, so `agent-fired.md` is a `regex`/`trace` `not_contains`
check on that error string instead. Needs
`--allow-tools Bash,Read,Grep,Glob,Agent,Edit,Skill`; the with-arm needs `defaultEnabled`
flipped true to load the plugin's skills at all, handled automatically via
`with_default_enabled_true` (see the runnable commands below).

Six for `performance-optimizer` (tag `performance-optimizer`, same skill mechanics and automatic
`defaultEnabled` flip as `code-architect`). Five
fire cases against small runnable JS fixtures with a `bench.js`: a nested-loop O(n²) lookup the
fix must convert to Map/Set and actually benchmark before/after via real `node bench.js` runs, not
invented numbers (`nested-loop-fix`); a function with no measurable bottleneck and no
benchmark/test infra at all, where the report must not assert a specific improvement number it
never actually measured (`cant-measure-refusal`); a deep-clone hot path with a caller that mutates
a nested field on the result, where the fix must stay a real deep clone and not regress to a
`{...obj}` shallow copy — this skill's own reference table names the trap (`shallow-copy-trap`); a
repeated-re-sort-for-min pattern where the reported complexity/impact numbers must match whatever
was actually shipped, not the reference table's heap-queue figure for a technique not built
(`numbers-match-fix`); and a bottleneck ruled architectural in the prompt (parallelization already
tried, hit a third-party vendor's hard rate limit and got the API key banned) where the report
must recognize the real constraint is structural/vendor-side and ask for an explicit decision
rather than shipping a local tweak that implies the volume problem is solved — naming
`backend-architect` by name isn't required, "this needs your decision on X" framing for the real
lever counts (`architectural-handoff`). Plus one should-NOT-fire case: a reported regression with
a before/after (5ms → 2s after a merge) is `mattpocock-skills:diagnosing-bugs`' literal trigger
per this skill's own Scope section, not this skill's — it must take a root-cause diagnostic
approach instead of jumping to speculative optimizations (`regression-routing`). Needs
`--allow-tools Bash,Read,Write,Edit,Grep,Glob,Agent,Skill`.

Six for `backend-architect` (tag `backend-architect`, agent — explicit dispatch instruction in
every fire-case prompt, `agent-fired.md` is a `not_contains` regex on the
`Agent type '...' not found` tool error, same automatic `defaultEnabled` flip as above). Five
fire cases against small scaffolded fixtures: a payment-claim worker whose `UPDATE` guards on a
different column (`charge_id IS NULL`) than the one it sets (`status`), letting two concurrent
workers both pass the claim guard and double-charge (`guard-column-bug`); a checkout endpoint that
charges whatever `priceCents` the client sends instead of re-deriving it from the catalog it never
calls (`client-trusted-price`); two service modules writing the same `orders` table directly ahead
of a planned split into separate deployables (`multi-writer-table`); a payment webhook handler with
no dedup/event-id tracking, so retried deliveries resend side effects like the confirmation email
(`no-idempotency-webhook`); and a broad "review the design before launch" request whose fixture
hides a real SQL-injection (string-concatenated query) — the report must notice it, explicitly
defer characterizing exploitability to `/security-review` per the agent's own documented handoff
rule, and not itself construct an attack payload or CVE-style writeup, while a short illustrative
before/after code snippet as part of its own architectural fix doesn't count against it
(`security-handoff`). Plus one should-NOT-fire case: "give me the files/interfaces/build order" for
one new endpoint is file-by-file blueprinting — `code-architect`'s territory per the cross-references
in both the `code-architect` skill and this agent, not a system-level review — so `backend-architect` must not be dispatched
(`file-blueprint-misroute`). Needs `--allow-tools Bash,Read,Grep,Glob,Agent`.

Six for `ideate-critic` (tag `ideate-critic`, agent — `mh:ideate`'s fresh-context Phase 2 critic,
strict JSON-in/JSON-out contract with `tools: Bash` only, no Edit/Write). `evals/ideate-run/`
already exercises it end-to-end via the full skill; these dispatch it directly with a hand-crafted
Phase-1-style idea envelope to probe its own specific failure modes. Five fire cases, four as plain
`prompt.md` + `graders/` (the envelope is inline JSON in the prompt, no fixture files needed): the
final message must be JSON only, nothing before `{` or after `}`, no markdown fence
(`json-only-contract`); an attractive-looking idea (an in-process cache that silently breaks past
one worker instance) must be flagged with a real `trap` reason and excluded from `shortlist`
(`trap-detection`); three near-identical paraphrases of the same read-through-cache mechanism from
three different frames must land in one cluster with `frameCount` 3, not split by surface wording
— two earlier fixture attempts using genuinely-distinguishable ideas kept getting correctly
re-split by the agent's own sharp reasoning before this near-paraphrase design finally worked
(`cluster-by-angle`); and `shortlistReasons`/`nonObviousPickReason`/`confidence.reason` must be
idea-specific arguments, not restated score numbers, on an idea list close enough in appeal to
tempt generic filler (`shortlist-reasons-specific`). The fifth fire case is prompt.md-only, no
`case.yaml`: `total`/`shortlist`/`runnerUp`/`nonObviousPick` must match `rank.py`'s own Bash
stdout verbatim, never hand-adjusted, and a `tool_used: Bash, input_match: rank.py` grader
confirms the agent actually piped through the script rather than computing totals by hand
(`rank-verbatim`) — needs `--allow-tools Bash,Read,Agent`.
Plus one should-NOT-fire case: `mh:ideate-critic`'s own description rules out code/security review
— a request to review a fixture with a real SQL-injection bug must not dispatch it
(`security-review-misroute`) — needs `--allow-tools Bash,Read,Grep,Glob,Agent`.

**A previously-invisible defect, found and fixed while calibrating `ideate-critic`:** the actual
`claude plugin eval` CLI only accepts `context.scaffold_script` as a relative path to an external
`.sh` file — a `scaffold_script: |` inline YAML block is silently mis-parsed as a literal path and
the case fails to load (`path "..." does not exist`), confirmed empirically case-by-case, at $0.00
each (the error fires before any agent turn). This affected all 46 of this file's pre-existing
`case.yaml` files (confirmed via `git ls-tree` at the commit before this fix) — the entire
pre-existing suite predating this file's `handoff` section — despite `tests/evals/test-eval-cases.sh`
reporting all of them `PASS`, because that script never invokes the real CLI: it only simulates
loading by extracting and running the inline block directly, which the actual CLI cannot do. All 46
have been migrated to external `scaffold.sh` files (same logic, relocated — not byte-identical: every
file gained a `#!/usr/bin/env bash` shebang, and 8 `compliance-audit-*` scripts also gained `|| exit`
after a `cd` to close a shellcheck SC2164 warning); `test-eval-cases.sh` itself has been updated to
read either form, to allow `prompt.md`-only cases (no `case.yaml`) and 2-grader cases with at least
one outcome grader (the two conventions this file's newer suites use), and its hardcoded case count
now reads 70 (see the `find` command at the top of this file — don't trust this literal either).
Spot-checked against the real CLI on both a trivial case (`cost-report-clean`) and a
complex one (`deep-audit-clean`, git-history scaffold) — both now load and run correctly.

**A follow-up `mh:deep-audit` pass** (fresh-context Codex checker, two rounds — every finding from
both rounds independently re-verified by direct file reads or a `python3 -c` regex repro before
being accepted or fixed) closed six real grading-logic gaps. Two needed a second attempt:
`code-architect-layer-direction/no-reverse-import.md`'s proximity-window regex rejected the
*correct* answer (matched `CsvExporter` and `from src.infra` even in the intended
composition-point import block); a first fix anchoring to `class CsvExporter` plus an indented
`from src.infra` line still false-rejected a correct answer formatted as an indented Markdown
list item with a fenced code block (confirmed via repro: Markdown list indentation reads the same
as "inside the class body" to a regex). Two independent counter-examples against two different
fix attempts is a sign this specific invariant can't be captured reliably by a regex over
free-form prose — `cites-analog-quality.md` (the case's LLM grader) already states the same
invariant correctly and with full semantic understanding ("Score 0 if the new exporter ...
imports infra directly"), so the regex was dropped rather than patched a third time.
`frontmatter-intact.md` had no delimiter check and no end-anchor on `owner:` (accepted deleted
delimiter lines or `owner: platform-other`; now checks both delimiters and both exact field lines
via a `-{3}` placeholder — a literal three-dash run previously broke this grader file's own
frontmatter parsing when it sat inside the `pattern:` value; the second round caught that the
first fix's own explanatory prose still spelled it out literally in three places, which turned out
harmless since prose sits after the file's real closing delimiter, but was corrected anyway since
the file's own comment claimed otherwise). The remaining four fixes held on re-verification: the 5
`handoff` `attempted-staging.md` graders checked `tool_used: Bash` with no `input_match` (any Bash
call passed; now requires `handoff-path.sh`, confirmed as the literal invoked filename in
`skills/workflow/handoff/SKILL.md`) — **historical**: the `mh:handoff` skill and its eval cases
were removed after this round; `handoff-path.sh`/`SKILL.md` no longer exist, this entry stays only
as the record of the fix; `code-architect-trivial-no-dispatch` had no check on the
actual edit's correctness (a half-rename leaving a `NameError` behind would have passed; added a
`not_contains: usr` check on the file); the 20 should-fire agent-dispatch cases across
`backend-architect`/`code-architect`/`performance-optimizer`/`ideate-critic` only proved the trace
*lacked* an "agent not found" error, never that dispatch actually happened (added a
`dispatch-confirmed.md` display-only `tool_used` trigger to each, `input_match` values confirmed
against each case's own `subagent_type`, `arm` left unset); and `test-eval-cases.sh` skipped its
own frontmatter/regex-compile validator entirely for prompt.md-only cases (an early `continue`,
contradicting its own comment) and counted "outcome graders" via a whole-file grep that a grader's
body prose could accidentally trip (both now scoped correctly — see the script's own comments).
All 70 cases still pass under the tightened checks (this number, like the one at the top of the
file, drifts as cases are added or removed — verify with the `find` command above rather than
propagating this literal further).

Run (needs Claude Code 2.1.269+; older builds print "currently in early access" — the command is
version-gated, not an account-level early-access flag, per `docs/en/plugin-evals.md`'s Requirements
section, confirmed via `claude plugin eval --help` on 2.1.280):

```bash
claude plugin eval . --scaffold --runs 1 --no-publish
claude plugin eval . --scaffold --tag silent-failure-hunter --runs 1 --no-publish
claude plugin eval . --scaffold --tag harness-audit --allow-tools Bash --runs 1 --no-publish
claude plugin eval . --scaffold --tag memory-lint --allow-tools Bash --runs 1 --no-publish
claude plugin eval . --scaffold --tag deep-audit --allow-tools Bash,Edit,Write --runs 1 --no-publish
claude plugin eval . --scaffold --tag cost-report --allow-tools Bash --runs 1 --no-publish
# These load an mh agent (subagent_type:) or skill (skill:), which needs the plugin actually loaded in
# the eval sandbox -- sandboxes load no user settings, so defaultEnabled: false never loads
# them (silent no-plugin fallback, no error). The helper needs bash specifically (it relies on
# BASH_SOURCE) -- it silently does nothing under zsh/sh, so run each line through `bash -c`
# regardless of your login shell; it flips defaultEnabled true for the duration and restores it
# after, even on failure -- no manual edit, nothing to remember.
bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval . --scaffold --tag code-architect --allow-tools Bash,Read,Grep,Glob,Agent,Edit,Skill --ablation with-without --no-publish'
bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval . --scaffold --tag performance-optimizer --allow-tools Bash,Read,Write,Edit,Grep,Glob,Agent,Skill --ablation with-without --no-publish'
bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval . --scaffold --tag backend-architect --allow-tools Bash,Read,Grep,Glob,Agent --ablation with-without --no-publish'
bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval . --scaffold --tag ideate-critic --allow-tools Bash,Read,Grep,Glob,Agent --ablation with-without --no-publish'
bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true claude plugin eval . --scaffold --tag ideate --allow-tools Agent,Bash,Read,Glob,Grep,Skill --runs 1 --no-publish'  # the run case spawns 6 agents (5 + mh:ideate-critic)
```

Cost and time: the last full run (2026-09-13, 76 cases, `-j 1`) took 34,801 s and $119.40; the
30 `runs: 3` cases were 66% of that, the without-plugin arm 31%, LLM graders 6%. Graders already
use the cheapest judge (`--judge-model` defaults to haiku), so do not raise it. Add `-j 4` to any
line above to run cases in parallel (same cost, roughly a quarter of the wall time; runs share one
rate limit), and `--max-cost-usd` to cap a run.

### Fold-vs-keep (one agent)

The `--ablation with-without` lines above turn off the whole plugin, so their without arm is the
built-in `Plan` (or general) agent, not this agent's own prompt. `scripts/eval-fold.sh` answers the
narrower question the fold-subagents audit asks (dotfiles repo,
`docs/research/fold-subagents-article-audit-2026-10-26.md`, recommendation 1): does the agent's
prompt do as well folded into a skill the main loop loads? It copies the
repo's tracked files into a temp dir twice:

- **kept**: the plugin as shipped (`defaultEnabled` set true in the copy only).
- **folded**: `agents/<agent>.md` removed; its body, byte-identical, becomes
  `skills/fold/<agent>/SKILL.md`, with frontmatter `name`, `description` and the agent's own
  `model:`/`effort:` pin. In every case whose first tag is the agent, the prompt's dispatch
  sentence asks for the `mh:<agent>` skill (Skill tool) instead, `Skill` joins `allowed_tools`,
  each Agent `tool_used` grader that names the agent checks the Skill tool instead, the
  `Agent type '...' not found` regex grader checks the Skill tool's `Unknown skill: <agent>` error
  instead (same file names), and the case gains `fold-agent-calls.md`, a display-only count of Agent calls. The build
  fails if a `subagent_type` is left, or if a fire case's dispatch sentence isn't found.

What "folded" does and does not hold equal:

- **Model and effort.** `claude plugin eval` has `--model` (every case, both variants) but no
  effort flag, so the pin rides in the skill's frontmatter instead: a concrete `model:` on a
  main-thread skill switches the model once the skill loads
  (`docs/reference/skill-authoring-conventions.md`). Turns before the Skill call still run on the
  eval child's model. The fold measures the agent's pin; a shipped fold then uses `model: inherit`
  (the convention), so it runs on the session's model.
- **Tool limits.** The folded variant gets the case's `allowed_tools`, not the agent's own
  `tools:` list. An agent with no Edit or Write whose cases allow Edit can edit, folded, where the
  subagent could not (the 2026-10-27 `code-architect` run had exactly this gap).
- **Delegation.** The folded main loop keeps the Agent tool. `compare` prints each folded run's
  Agent call count (from the runner's own `Agent called Nx` grader explanation; trace files are
  deleted after a run) and flags `DELEGATED` when a run still handed work to a subagent; `?`
  means the count was unreadable, not zero.

Both run with `--ablation none` and `--runs 2` or more (the script refuses fewer), then
`scripts/_lib/eval-fold.py compare` prints each case's graders run by run (`PP` / `PF` / `FF`,
`E` for an errored run, `S` for a run that hit `--max-cost-usd`, whose `skippedPaidGraders` left
its llm graders marked failed without judging) for both variants, a `*` on every grader whose
pass rate changed (a flipped task), and the per-case outcome mean. `E` and `S` runs stay out of
rates, flips, means and the verdict, and each kind is counted at the end; the cap is per variant,
so one capped variant would otherwise read as a fake "folded worse". `agent-fired`, `dispatch-confirmed` and `fold-agent-calls`
show whether the variant's mechanism ran and are left out of the score. Rule: keep the subagent
only if the folded variant scores worse. The shipped plugin gains no skill: the folded copy only
exists in the temp dir.

```bash
bash scripts/eval-fold.sh plan-reviewer             # free: builds + validates both copies, prints example eval commands
bash scripts/eval-fold.sh plan-reviewer --run -j 4 -- --max-cost-usd 25   # paid
```

Without `--run` the temp dir is removed on exit, so the printed commands are examples of what
`--run` executes; add `--keep` to leave the dir in place and run them by hand.

Agent names: any agent with tagged cases whose fire prompts use the standard dispatch sentence
(`plan-reviewer`, `blind-spot-hunter`, `silent-failure-hunter`, `test-gap-analyzer`,
`type-design-analyzer`, `backend-architect`, `requirement-analyst`; `ideate-critic`'s prompts
don't, so its build stops). The 2026-10-27 runs folded worse on 0 cases for each of
`code-architect`, `backend-architect`, `requirement-analyst` and `performance-optimizer`; the
operator shipped `code-architect` and `performance-optimizer` as skills and kept the other two as
agents (a scored reviewer, maker≠checker; a read-only boundary for untrusted tickets, with no
injection case in the eval).
Results: `evals/results/fold-<agent>-<timestamp>/{kept,folded}/aggregate-result.json` and
`compare.txt`. The copy holds tracked files only (working-tree bytes), so commit or `git add` a
new case before running it.

Cost, from the 2026-09-13 run above: about 272 agent runs (30 cases x 3 + 46 x 1, two arms) for
$119.40 and 34,801 s, so roughly $0.44 and 128 s a run. At `--runs 2` a six-case agent is
6 x 2 x 2 = 24 runs: about $11 and 50 min at `-j 1`, 13 min at `-j 4`; a two-case agent is 8
runs: about $4. That average includes the cheap without-arm runs; these cases run 20+ turns and
both variants run on the agent's pinned model, so budget up to twice that. Arguments after `--` go to both variants, so
`--max-cost-usd 25` caps each at $25.

`--scaffold` is required: the fixtures live in each case's `scaffold_script`, which must be a
relative path to an external `.sh` file in the case directory — never inline YAML block content
(see the defect note above).
`tests/evals/test-eval-cases.sh` checks the cases statically (`prompt.md` always, `case.yaml` only
when the case needs scaffolded fixtures, at least one outcome grader, scaffold scripts run and
produce the fixture files, regex graders compile, and each `contract.md` / `clean.md` regex matches
a verdict sample in the shape the agent actually emits: bare, bold, or after a `Verdict:` label —
skipped for agent-dispatch suites with no fixed verdict token, whose content was verified via real
ablation pilots instead) so the suite stays loadable while the runner is gated. Results land in
`evals/results/`, gitignored. Keep the newest 5 runs; archive older runs as
`$HOME/.cache/mh/eval-results-<date>.tgz`.
