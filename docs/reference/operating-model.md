# Operating model

Three ideas hold the plugin up. Everything else is a consequence.

## 1. Deny the irrecoverable set computationally; advise on the rest

A hook can deny a tool call before it runs. That is the only place a rule is a guarantee
instead of a hope, so the deny list is kept small and literal: the set of actions no later
step can undo. The `PreToolUse` entries in `hooks/hooks.json` are the whole list of those; one
`SubagentStop` entry is listed alongside them for the same reason (it enforces a rule
mechanically, from a file in `hooks/gates/`), even though it blocks a subagent's *Stop*, not a
tool call — see its own row below for what that means in practice:

| gate | denies or asks |
|---|---|
| `gate:bash:irrecoverable` | `rm -rf`, `find -delete`, `find -exec rm` and `xargs rm` (any flags: a delete of every path fed to it), `--no-verify`, `hooksPath` edits, `push --force` (and `push --mirror`/`--prune`, a push deleting main/master/develop, and the same through `send-pack`: `-f`/`--force`, `--mirror`, a `+refspec` or a `:main` delete), `reset --hard` (and `read-tree -u --reset`, `checkout-index -f`, `worktree remove --force`), `reflog expire`/`delete` and `gc`/`prune` at now/all, `update-ref -d` or `branch -M`/`-C` onto main/master/develop (and `branch -f`, `-m`/`-c` with `-f` bundled or not, and `update-ref` moving one), `rm -f` (not `--cached` or a dry run, last flag winning), `clean -f`, discarding `restore`/`checkout`, `branch -D` (a plain `git branch -D <names>` without main/master/develop is allowed), `stash drop/clear`, `commit --amend`, `dd` or `gdd` to a device (`/dev/null`, `/dev/zero` and stdio excepted; an `of=` held in a variable or substitution asks), `mkfs`, `chmod` 777/`a+rwx` recursively or on `/` or `~`, `rm --no-preserve-root`, SQL `DROP TABLE`/`DATABASE`/`SCHEMA` and `TRUNCATE` (not `DROP INDEX`/`VIEW`), `git add -A` outside a merge, nested `claude` spawns from a subagent (a prompt word, piped or `<` stdin, `-p`/`--print`, `--agent`, `--bg`/`--background`, `-w`/`--worktree`; `--version`/`--help` anywhere and a first-word subcommand that starts no session, such as `mcp` or `doctor`, stay allowed). Journals only, in shadow (GH #337): an ask on `source`/`.` of a file and on a program named by a variable with no visible assignment. Asks (never denies) on `gh pr merge`, `gh api .../merge`, a `gh api` write (non-GET method, a field or `--input` with no method, a graphql mutation; issue/PR comments and labels excepted), a `gh` alias or extension, and a T3/T4 built-in write (`gh repo delete/archive/rename/edit`, `secret`/`variable set/delete`, `release delete`, `ssh-key`/`gpg-key`/deploy-key `add/delete`, `extension install/exec`, `alias set`, `issue delete/transfer`, `workflow run`, `run cancel/rerun/delete` and a few more in `_GH_BUILTIN_WRITES`; `release upload --clobber` and `repo sync --force` in `_GH_BUILTIN_FORCED`), with the verb found the way gh's parser finds it, so a flag before the verb or the group (`gh secret -e prod set`, `gh -X DELETE api`), a group alias (`cs`, `ext`) and a `$(...)` in the group or verb slot are still seen; a built-in's `-h`/`--help` (outside `extension exec`), a pflag false value (`--clobber=false`) and words after `--` do not ask |
| `gate:bash:subagent-git-guard` | `git stash`/`reset`/`clean` from a dispatched subagent |
| `gate:agent:subagent-spawn-guard` | a subagent calling the Agent tool to spawn its own reviewer/validator |
| `gate:task:complete-separation` | a subagent marking its own task complete |
| `gate:write:test-integrity` | asks before a write that weakens a test |
| `gate:write:config-guard` | asks before a write to Claude Code settings `hooks`/`enabledPlugins` |
| `gate:write:secret-scan` | asks when a Write/Edit introduces a new vendor-specific live-credential-shaped token (AWS, Anthropic, OpenAI, GitHub, GitLab, HuggingFace, Slack, Stripe, Google, npm, PyPI, PEM) that isn't a canonical placeholder or same-line-suppressed — the only mechanism catching a pasted secret today; `MultiEdit`, Bash-mediated writes, and Codex-rescue writes bypass it with no other backstop (`git-hooks/pre-commit`/`pre-push` have zero secret-content scanning) |
| `gate:skill:codex-setup-guard` | asks before a model-invoked `Skill(codex:setup)` call carrying `--enable-review-gate` |
| `gate:tool:routine-trigger-guard` | asks before `RemoteTrigger`'s `create`/`update`/`run`/`create_webhook_trigger` actions create, modify, or fire a Routine (a cloud session) — not its `list`/`get`/`list_runs`/`get_run_log` reads. `CronCreate` is out of scope: it only re-enqueues a prompt in the same, already-attended session (session-only, no new credential), found misclassified as a Routine trigger by `mh:deep-audit` 2026-09-28. Interactive-session-only, same posture as `gate:bash:irrecoverable`'s `gh pr merge` ask rule; cannot constrain a Routine already running outside this session (`docs/adr/0004-operator-authorized-routine-self-launch.md` §4) |
| `gate:agent:subagent-verdict-check` | `SubagentStop`, plus a `PreToolUse` twin (`gate:agent:subagent-verdict-check-handback`, matcher `SubagentHandback`) that runs the same check on `tool_input.message` for the auto-mode delivery path on CC >= 2.1.271 (GH #160; the deny is a re-prompt with no counter, bounded by Claude Code's own turn budget): blocks a subagent's Stop and re-prompts it once when its final message contains a Rule 13 `{pass, findings[], checked[], scope_ok, unexpected_files[]}`-shaped object that is vacuous (`pass:true` with both `findings[]` and `checked[]` empty) or self-contradictory (`pass:true` with `scope_ok:false` or a non-empty `unexpected_files[]`); allows on `stop_hook_active:true`, `NEEDS-DECISION`, ambiguous multi-candidate output, or no verdict-shaped output at all |

Everything not in that table is advice: METHODOLOGY.md text, skill prose, agent guardrails.
`sensor:bash:output-redact` is advice too, not a gate: a `PostToolUse` hook that replaces
vendor-shaped credential tokens (`secret-scan.py`'s patterns, with the leading word boundary
dropped and whole PEM blocks taken) in Bash stdout/stderr (`updatedToolOutput`) and in the
text blocks of an MCP tool's result, including an embedded resource's text
(`updatedMCPToolOutput`, matcher `mcp__.*`), with `[REDACTED:<kind>]`. It is best-effort: a
token outside those shapes, one split across stdout and stderr, Read output, a
`run_in_background` run's output file (read back through Read), and an MCP result that is
not a list of content blocks (a dict with `structuredContent`) or a non-text block pass
through unredacted. On an error or a timeout the original output stays visible (fail-open;
exit 1, invalid JSON, exit 2 and a timeout probed for Bash on CC 2.1.307, GH #534; MCP
shares the code path and is not separately probed). A foreground Bash output over 30 KB is
saved to its file already redacted; that was not probed for MCP.
Advice is honest about being advice; no doc claims a check enforces a rule unless a file in
`hooks/gates/` does.

Each gate owns its error path, and the policy is written in the gate, not assumed: input
`irrecoverable.py` cannot tokenize denies (exit 2, `could not safely tokenize ... - confirm with user
first`), since an unparsed command could hide any write; a missing `python3` always allows, announced
on stderr (#93); a missing sibling script denies (exit 2) for `irrecoverable.py`, but allows
(same stderr-note posture) for the four subagent-scoped gates (`subagent-git-guard`,
`task-complete-separation`, `subagent-spawn-guard`, `subagent-verdict-check`), for
`routine-trigger-guard` (tool-scoped, not subagent-scoped, same allow-on-missing-sibling
posture), for the three ask-only write gates (`test-integrity`, `config-write-guard`,
`codex-setup-guard`), and for `secret-scan.py` — its verdict is advisory on a write already happening, and it
runs on every Write/Edit in every host project loading this plugin, so an internal exception
there also allows rather than asking. `scripts/gate-canary.sh` proves
every staged gate still allows benign payloads. The table is the contract; the hook type is
not. Claude Code's proposed function hooks (anthropics/claude-code#91870, prototype behind
`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` since 2.1.260; `claude plugin validate` already lists a
module's hooks and `$` calls on 2.1.263) skip a hook that throws, turn every function hook off
for the session when the hooks worker crashes, and evaluate matchers once before the chain. A
gate ported there must catch and deny on its own error and sit above any hook that rewrites
the event.

**The principle behind that per-gate table, stated once:** fail closed when the verdict
authorizes an action; fail open to the native/no-op path when the verdict only optimizes one
that was already going to happen anyway. `irrecoverable.py` denies on a missing sibling because
its verdict gates an irreversible command; the four subagent-scoped gates allow on the same
failure because their absence just returns the session to unguarded-but-otherwise-normal
behavior, not to a worse state than before the gate existed. A new gate's error path is decided
by which side of that line its verdict sits on, not by copying an existing wrapper's style.

## 2. The maker never grades its own work

An LLM cannot reliably judge output it produced in the same context — self-preference bias is
structural, not a capability gap that shrinks as models improve (2026 benchmarks still find
frontier models giving their own model family 75-84% win rates in self-judged comparisons; see
`docs/research/autonomous-loop-doctrine-drilldown-2026-09-28.md` Finding 2a for sources). So:

- A builder that touched 2+ files or a test gets a fresh-context validator (METHODOLOGY Rule 13).
- Reviewer agents are read-only (`harness-audit` check 32) and return findings, never a verdict
  that ships the work by fiat.
- Every `harness-audit` check has a fires/silent pair in `tests/skills/harness-audit/` (fixture
  pairs; check 43 varies the budget env against the clean fleet, with the ceiling pinned);
  a full run WARNs when a top-level surface dir (`agents/`, `skills/`, `hooks/`) is missing. An
  empty surface dir still passes its checks vacuously; the guard names only the missing dir.
- The six review agents (`plan-reviewer`, `blind-spot-hunter`, `silent-failure-hunter`,
  `requirement-analyst`, `test-gap-analyzer`, `type-design-analyzer`) have a planted-defect case and a clean control each
  under `evals/`, in `claude plugin eval`'s native layout, graded on their own Output Format
  (`evals/README.md`). The other agents with cases are `backend-architect`, `code-architect`,
  `ideate-critic`, and `performance-optimizer`; the skills are `tech-humanize`, `ste-lint`,
  `harness-audit`, `memory-lint`, `deep-audit`, `compliance-audit`, `idea-audit`, `learn`,
  `post-mortem`, `cost-report`, and `ideate`. `tests/evals/test-eval-subjects-doc.sh` fails when
  this list and the subjects under `evals/` disagree. Count drifts as suites are added; recompute with
  `find evals -mindepth 1 -maxdepth 1 -type d ! -name results | wc -l` rather than trust a
  literal number here (`evals/README.md`). The runner is early-access gated;
  `tests/evals/test-eval-cases.sh` keeps the cases loadable until it opens and proves every
  regex grader against its fixture or verdict sample.
- `gate:task:complete-separation` makes the rule mechanical for task state.
- A finding from a reviewer/checker (Codex adversarial pass, `blind-spot-hunter`, any Rule-13
  validator) is not self-authorizing: applying its fix still needs the human's own
  confirm-then-fix gate, even when the finding is clearly real and the same session already ran
  one such gate earlier in the same audit. This has lapsed under task momentum twice
  (2026-09-25, 2026-09-29) with the model itself having read the rule going in both times —
  knowing the rule in the abstract does not stop it lapsing under momentum, so treat "does this
  finding still need its own gate" as a checklist item at the moment a finding is confirmed, not
  something inferred from having asked once already in the same run.

The same rule at fan-in: when N subagent outputs feed one synthesis, agreement and conflict are
surfaced explicitly and malformed entries are dropped by a stated rule, not by the synthesizing
model's unaided judgment.

## 3. Score, not feel

An important decision carries stated criteria, weights, a numeric result, a pass/fail reason, and
a confidence band (high/medium/low) with its reason (METHODOLOGY Rule 14). "Important" means the
Rule 1 triad flagged it (one-way door, wide blast radius) or the user asked for a ranking. Routine
calls get one line with the reason. Insufficient data is marked `ข้อมูลไม่เพียงพอ` and blocked on
the operator; a guessed score is worse than none.

Evidence is read in order: deterministic results first (a test exit code, a grep count), then
the trajectory of this run, then how often work from this source has been rolled back before,
and the model's own confidence last. Confidence is the weakest input because it is the only one
the model controls.

## What this plugin deliberately does not do

- No autonomous loop: the model never starts work on its own; every wave begins with a human.
  `/goal` and `/loop` are the operator's to type. `/goal`'s evaluator is a session-scoped
  prompt-based Stop hook on the small fast model; it reads only the transcript and never calls
  tools (`code.claude.com/docs/en/goal`), so it checks that the stated condition appears met,
  not that the work is right. It does not replace the Rule 13 fresh-context validator, and it
  has no native turn cap: the cap is a clause in the condition.
- No orchestration layer of its own: dispatch shape is one page (`spawn-brief.md`); Claude
  Code's native Agent tool does the rest.
- No response style of its own: the `ponytail` plugin is the only style layer.
