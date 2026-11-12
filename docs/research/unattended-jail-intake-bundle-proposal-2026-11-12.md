# Proposal: unattended agents with no write access (option A)

> **Status (2026-11-12): NO-GO, not built, superseded.** This is the working file of an
> `mh:attack-proposal` run, kept as a record. Four attack lanes found 26 breaks in the first
> text (the body numbers 23, B1 to B23; the record does not say how 26 became 23); three validator
> rounds closed them or left them as accepted residuals (B5, B11) and each found 2 or 3 new ones,
> every one of them in the owner-side intake script that parses the agent's git bundle. No new
> break landed in the jail half after revision 1, though revision 2 tightened its forwarding proxy
> on the validator's notes. Validator round 3's result is not written into this file. The two breaks open at the end (the host pushing from a repository a container
> wrote, and binary files skipping the hidden-character scan) are not fixed here. The next design,
> which drops the intake script, is `unattended-jail-branch-key-proposal-2026-11-12.md`.
> Every attacker and validator was Claude (no Codex in the session, so independence was reduced),
> round 1's output did not go through the mechanical verdict and citation checkers, and no
> container behaviour was run. Read later sections as overriding earlier ones.

Version 3 of the "take the human out of the loop" design for `wasikarn/method-harness` (the `mh`
Claude Code plugin). Versions 1 and 2 failed attack rounds for one shared reason: everything that
judged the agent's work was writable by the agent, or ran the agent's code with the owner's
privileges before the owner had seen it. Option A removes the agent's write access entirely.

## The problem

The owner wants scheduled, unattended Claude Code runs (launched by the `agent-autoloop` daemon:
`claude -p <prompt> --permission-mode bypassPermissions ...`) to do real work on this repository
while the owner only approves. The repository is public, owned by a personal GitHub account, has
no CI, and its merge gate (`scripts/merge-pr.sh`) runs the checkout's own gauntlet on the owner's
machine. An unattended run reads untrusted text (issue bodies, web pages, repository content), so
it must be assumed that a run can be steered by that text.

## The change

### Principle

An unattended run holds **no credential that can change anything outside its own jail**, and the
owner's side **never executes or trusts anything the run produced until the owner has approved the
diff**. The only thing that leaves the jail is a git bundle file and a note. Approval is one act:
the owner reads the diff and pushes the branch. After that the existing attended flow applies
unchanged (PR, fresh-context review, `merge-pr.sh`).

### J. The jail (where an unattended run lives)

- J1. A dedicated container or VM (not a second OS user on the owner's desktop). The owner's home
  directory, SSH agent, Docker socket, keychain and `~/.claude` are not mounted. One host
  directory is mounted read-write: the **outbox**. Nothing else is shared.
- J2. No GitHub credential of any kind inside the jail: no token, no SSH key, no `gh` login, no
  git credential helper. The clone comes from the public HTTPS URL anonymously, and
  `git fetch origin` keeps it current. The run cannot push, comment, open a PR, set a status or
  create a gist, because it has nothing to authenticate with.
- J3. The only secret inside the jail is one Anthropic API key from a dedicated Console workspace
  with a provider-side monthly spend limit. Not the owner's subscription login, so no claude.ai
  connectors (mail, drive, calendar) exist in the run.
- J4. Network egress from the jail is an allowlist: `api.anthropic.com`, `github.com` and
  `codeload.github.com` (anonymous read), and the package registries the gauntlet needs. No route
  to the host's loopback services or the LAN.
- J5. `agent-autoloop` runs inside the jail, as the jail's user. Its cards and "ask first" prompts
  are notification only: nothing on the owner's side treats an answered card as an approval,
  because the run can answer its own cards.
- J6. `mh` is installed in the jail unchanged. Its gates protect the run from its own mistakes
  (a hook "ask" is a denial in a `-p` run, and the model reads the reason). No gate is weakened
  for unattended use. Where a gate stops the work, the run says so in its note.
- J7. One run at a time (`maxActive: 1`), scheduler timeout as configured. Orca is not used for
  unattended runs: it works in the owner's account with the owner's credentials, so every Orca
  session counts as attended.

### H. The hand-off (the only thing that leaves the jail)

- H1. The run commits on a local branch `agent/<task>` in its clone.
- H2. It then writes two files into the outbox: `<task>.bundle` (`git bundle create` of that
  branch against `origin/develop`) and `<task>.note.md` (what it did, what it could not do, the
  tests it ran and their result). Both are untrusted data to everything outside the jail.

### I. Intake (the owner's side; new script `scripts/agent-intake.sh`, run by the owner)

The script is run from the owner's checkout of `develop`, so the copy that runs is the base
branch's, never the agent's.

- I1. `agent-intake.sh list` names the bundles waiting in the outbox. It opens only regular
  files directly inside the outbox (no symlink, device, FIFO or subdirectory is followed), and
  refuses a bundle over a size cap (default 20 MB).
- I2. `agent-intake.sh show <task>` fetches the bundle into a **quarantine repository**: a bare
  repository the owner created, separate from the working clone, holding a mirror of
  `origin/develop`. The fetch uses `transfer.fsckObjects=true` and maps the bundle's branch to
  `refs/agent/<task>`. Nothing is checked out anywhere. It then prints, with all output passed
  through a filter that renders control characters visibly:
  - the commit list and diffstat of `origin/develop...refs/agent/<task>`, after first fetching
    `origin/develop` from GitHub;
  - **judge paths touched**: any change under `scripts/`, `git-hooks/`, `hooks/`, `tests/`,
    `.claude/`, `.claude-plugin/`, `skills/meta/harness-audit/`, `evals/`, or to `CLAUDE.md`,
    `docs/METHODOLOGY.md`;
  - removed or changed assertion lines in test files;
  - secret-pattern hits in added lines (`hooks/gates/secret-scan.py`'s patterns, from the base
    branch's copy);
  - files that are symlinks, submodule entries (`.gitmodules`, gitlinks), binary files, files
    over 1 MB, and added lines holding bidirectional or zero-width Unicode;
  - the note, as plain text, truncated to 200 lines;
  - the full diff, through the same filter, in a pager.
- I3. `agent-intake.sh push <task> <sha>` is the approval. The owner passes the commit id that
  `show` printed. The script pushes exactly that object from the quarantine repository to
  `origin` as `claude/agent-<task>`, with the owner's credentials, and refuses when
  `refs/agent/<task>` no longer resolves to that id. It runs no hook from the agent's tree: the
  quarantine repository is bare and has only its own default hooks directory. It does not open
  the PR and does not post the note anywhere.
- I4. `agent-intake.sh drop <task>` deletes the quarantine ref and moves the outbox files to a
  `rejected/` directory outside the outbox.
- I5. Optional pre-approval evidence, `agent-intake.sh verify <task>`: runs the gauntlet on the
  agent's commit inside a **fresh throwaway container** (an image the agent never ran in, no
  network, the quarantine repository mounted read-only, no outbox), and prints the exit code and
  the last 40 log lines through the filter. This is advice: the commit's own code runs the tests,
  so a pass proves little when judge paths are touched, and `show` says so in that case.

### After approval

The pushed branch is an ordinary `claude/` branch. The owner opens the PR, a fresh-context review
runs in an attended session, and `scripts/merge-pr.sh` runs the gauntlet on the owner's machine
and merges. From the push onward the agent's code runs with the owner's privileges; the approval
in I3 is the owner's statement that the diff is acceptable to run.

### Changes to mh

- New: `scripts/agent-intake.sh` with its tests, a section in
  `docs/reference/branching-model.md`, a row in `scripts/gauntlet-rules.txt`.
- New: `docs/reference/unattended-jail.md` describing J1 to J7 as requirements on the operator's
  setup. The jail itself is the operator's container configuration, not code in this repo.
- No gate, hook, sensor or existing script changes.

## Must stop

- S1. A run changes the GitHub repository in any way without the owner's `push`. Example: a run
  steered by an issue body tries `git push origin HEAD:develop`, `gh pr merge`, or a `curl` to the
  statuses API.
- S2. A run reads or sends out anything of the owner's. Example: `cat ~/.ssh/id_ed25519`,
  `cat ~/.aws/credentials`, reading the owner's `~/.claude` session transcripts, reading mail
  through a claude.ai connector.
- S3. Anything the run wrote executes on the owner's side before `push`. Example: a hook, a
  `.gitattributes` text-conversion driver, a git config value, a file name or a note that makes
  `list`, `show` or `verify` run a command as the owner.
- S4. The owner approves one thing and another is pushed. Example: the bundle is replaced between
  `show` and `push`; the diff shown is against a different base than the PR will have; hidden
  characters make the shown diff read differently from what it does.
- S5. Agent-written text reaches GitHub under the owner's name without the owner choosing it.
  Example: the note is used as a PR body or comment automatically.
- S6. A run spends without bound. Example: a retry loop that runs for days, or the API key copied
  to a pastebin.
- S7. Damage on the owner's side from intake itself. Example: a 50 GB bundle fills the disk; a
  symlink in the outbox makes `list` print or move one of the owner's files; `drop` deletes
  something outside the outbox.

## Must allow

- A1. A run fixes a bug with a test, commits, and hands off; the owner reads `show`, runs `push`,
  and the normal PR flow follows. Example: the `bash-output-redact` fix in PR #1019.
- A2. A run changes judge paths legitimately (a new test file, a script fix) and the owner can
  still take it: `show` flags it, it does not refuse it.
- A3. A run that a gate stopped still hands off what it has, with the gate's reason in the note.
- A4. Several tasks wait in the outbox at once and the owner takes them in any order.
- A5. `develop` moves between the run and the intake: `show` still gives a correct diff against
  the current `origin/develop`, or says plainly that the branch needs a rebase.
- A6. The owner's attended sessions (terminal, Orca) work exactly as today.
- A7. The run can install dependencies and run the full gauntlet inside the jail.

## Known facts

Earlier work searched: the two earlier proposals in this session (versions 1 and 2, both failed),
`docs/adr/` (0001 to 0005), `docs/reference/branching-model.md`, `docs/reference/operating-model.md`.
No `qmd` collection and no `gh` are available in this session, so issues and open PRs were not
searched: none listed.

Verified:

- K1. In a `-p` run a PreToolUse hook's "ask" is a denial and the model reads the reason, also
  under `--permission-mode bypassPermissions` (live probe, claude 2.1.322, earlier in this
  session).
- K2. Fetching a bundle file into a bare repository does not run anything from the repository
  that made the bundle. Probe on git 2.43.0: the source repository had a `diff.*.textconv` driver,
  an `uploadpack.packObjectsHook` and a `post-checkout` hook, each writing a marker file;
  `git -c transfer.fsckObjects=true fetch <bundle> refs/heads/main:refs/agent/t1` into a bare
  repository, then `git diff` there, wrote no marker. A `.gitattributes` in the fetched tree
  naming `diff=evil` had no effect, because the driver is defined only in the source's config.
- K3. `git diff` prints a symlink entry as its target text (`+/etc/passwd`), without following it.
- K4. `git mktree` accepts a tree entry named `.git` (it returned an object id); whether
  `transfer.fsckObjects=true` rejects such a tree on fetch was not run.
- K5. GitHub: any identity with write access to a repository can set any commit status, and
  push restrictions and bypass lists exist only for organization repositories (docs, round 1).
- K6. `scripts/merge-pr.sh` and `scripts/sync-pr-head.sh` run the checkout's own
  `scripts/run-gauntlet.sh`, so after a push the PR's code runs as the owner.
- K7. The repository's `core.hooksPath` is set per clone to the relative path `git-hooks`
  (`CLAUDE.md`), so a bare repository created elsewhere has no project hooks.
- K8. autoloop's worker copies the environment to the child except `AGENT_AUTOLOOP_*`,
  `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*`, and its hub keys live in the account it runs as
  (its manual, round 1).
- K9. A review run on 11 real PRs of this repo found the later-fixed bug in about half the runs
  at best (16 to 18 of 33 on sonnet, 15 to 16 of 21 on opus). A model review is advice, not a
  gate.

**Unverified. These are the first targets:**

- V1. `transfer.fsckObjects=true` on a fetch from a bundle rejects every object shape that could
  later hurt the owner's side (a tree entry named `.git` or a case or Unicode variant of it, a
  malicious `.gitmodules`, an over-long path), and a bundle cannot make the fetch write a ref
  other than the one the refspec names.
- V2. Nothing in the owner's global or system git configuration (a global `core.hooksPath`,
  `core.fsmonitor`, a credential helper, `url.*.insteadOf`, a global attributes file with a diff
  driver, `diff.external`, a pager setting) makes `fetch`, `diff`, `log` or `push` in the
  quarantine repository run agent-influenced input as a command.
- V3. The control-character filter is enough: no file name, ref name, commit message, author
  field or diff line can make the owner's terminal or pager do anything, and `git` quotes unusual
  path names the same way in every command `show` uses.
- V4. `push <task> <sha>` pushes exactly the reviewed object: nothing between `show` and `push`
  (a new bundle of the same name, a second `show`, a ref the bundle named differently) changes
  what is sent, and the diff the owner read is the diff the PR will show.
- V5. The judge-path list in I2 is complete: no file outside it changes what the gauntlet, the
  audit, the git hooks, the plugin's hooks or `merge-pr.sh` do. And the removed-assertion and
  secret scans cannot be dodged by ordinary means (a renamed test file, a test that still exists
  but no longer runs, a secret split across lines or encoded).
- V6. A container on the owner's machine with only the outbox mounted gives S2: no default
  mount, socket, forwarded agent, metadata service or host-loopback route exposes the owner's
  files or credentials. On macOS this means Docker Desktop or a similar VM.
- V7. A `-p` run authenticated with a Console API key has no claude.ai connectors and no access
  to the owner's claude.ai data.
- V8. An anonymous clone and fetch of the public repository works from the jail at the rate the
  schedule needs, and the gauntlet can run in the jail (it failed on two files in this session's
  root container: `tests/scripts/test-gate-differential.sh` and
  `tests/skills/memory-lint/test_memory_lint.py` need a non-root user).
- V9. mh's gates, unchanged, leave an unattended run able to do ordinary work: commit by explicit
  path, run tests, delete its own temporary files, edit test files. Known frictions: the
  `test-integrity` gate asks (so denies) on any removed assertion line; `irrecoverable` denies
  `rm -rf` and `git add -A`.
- V10. `verify` in a throwaway container cannot affect the owner's side: the mounted quarantine
  repository is read-only, and the log tail is only displayed.
- V11. The spend limit on a Console workspace is a hard stop, and a leaked key can be revoked
  without touching the owner's own sessions.
- V12. `agent-autoloop` can run wholly inside a container, and with `maxActive: 1` and its
  timeout it never leaves two runs writing the same clone.

## What versions 1 and 2 got wrong, and what option A claims instead

Treat each claim as something to break.

| Earlier break | Option A's claim |
|---|---|
| The agent posts its own verdict, status or merge | It has no credential (J2); the only path to GitHub is the owner's `push` (I3) |
| The PR replaces the judge (`run-gauntlet.sh`, tests) | Nothing of the PR runs as the owner before approval; `show` flags judge paths (I2) |
| `approval-brief.sh` ran PR code as the owner | Intake only fetches and diffs; `verify` runs in a throwaway container (I5) |
| Forged pass cache or replay record | Agent-side results never leave the jail except as note text, which is untrusted |
| The agent switches off hooks or edits settings | Only its own jail is affected; no control on the owner's side lives in the jail |
| A secret committed through Bash | No owner secret is in the jail (J1, J3); `show` scans added lines |
| Peers' worktrees destroyed | One run at a time in the jail's own clone (J7) |
| `ask` turns into deny and blocks ordinary work | Accepted: the run reports the stop in its note (J6, A3) |
| Second OS user leaks files and sockets | Container or VM with one mount (J1) |
| Fan-out, retry loops, spend | `maxActive: 1`, timeout, provider-side cap on a dedicated key (J3, J7) |

## Revision 1

Round 1 ran four attack lanes and returned 26 breaks; three were reproduced by the author (B12,
B13, B14) and the rest are taken as confirmed on the attackers' own command output. Where this
section and the text above disagree, this section wins. One line per break: closed how, or
dropped, or accepted as a stated residual.

Design changes that several closes share:

- **R-KEY. No secret inside the jail at all.** The Anthropic key lives in a small forwarding proxy
  outside the jail. The jail's only egress is that proxy and a filtering HTTP proxy for the read
  hosts; `ANTHROPIC_BASE_URL` points at the forwarding proxy, which adds the key header, accepts
  only `POST /v1/messages` and `POST /v1/messages/count_tokens`, rejects a request body that names
  `mcp_servers` or a server-side tool (`web_fetch`, `web_search`, `code_execution`), and enforces
  a daily request budget. The key is a workspace-scoped key of a dedicated workspace. The jail
  has no direct DNS: names resolve only inside the two proxies.
- **R-GIT. Every git command intake runs is pinned.** `GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_CONFIG_NOSYSTEM=1`, `-c core.quotePath=true`, `--no-tags` on every bundle fetch, full ref
  names only (`refs/remotes/origin/develop`, `refs/agent/<task>`), `--no-renames` on every scan,
  `--` before every path argument, and the bundle always passed as an absolute path. The owner's
  credential helper is supplied only to the one `push` command. The quarantine repository is
  made with `git init --bare` plus an explicit fetch of `refs/heads/develop`, never
  `clone --mirror`, and `push` names the URL, not a remote.
- **R-NAME. Task names are `^[a-z0-9][a-z0-9-]{0,40}$`.** An outbox entry whose name does not
  match `<task>.bundle` or `<task>.note.md` under that pattern is never opened and never printed;
  `list` reports only how many such entries exist.
- **R-FILTER. One output filter for everything intake prints** (`list`, `show`, `verify`, error
  text): bytes in printable ASCII, newline and tab pass; every other byte or code point is
  printed as a visible escape. Applies to paths, ref names, commit messages, author fields, the
  note and the diff.
- **R-SHAPE. `show` refuses, before printing any diff, a branch that is not a plain line of
  commits on top of `origin/develop`:** every commit in
  `refs/remotes/origin/develop..<sha>` has exactly one parent, `git merge-base --all` returns
  exactly one commit, and that commit is an ancestor of `refs/remotes/origin/develop`. It also
  refuses when `git fsck --strict` on the fetched commit's objects reports anything, when any
  new blob is over 1 MB or the new blobs total over 20 MB (`git cat-file --batch-check`, before
  any diff is computed), when any tree entry is a gitlink, or when an added line or a path holds
  a code point outside printable ASCII, newline and tab (override flag
  `--allow-non-ascii`, which still prints them escaped). After every fetch it checks that the
  quarantine repository's ref list is exactly `refs/remotes/origin/develop` plus `refs/agent/*`,
  and deletes the task's ref and refuses otherwise.

Per break:

- B1 (key sent out through `mcp_servers` or server-side `web_fetch` on the allowlisted API host):
  closed by R-KEY; the run never holds the key and the proxy rejects those request shapes.
- B2 (key committed and pushed with an attacker-supplied token, or `npm publish`): closed by
  R-KEY; there is no secret in the jail to send. The jail's other content is a public repository.
- B3 (unscoped key reaches other workspaces and the Admin API): closed by R-KEY (workspace-scoped
  key, two allowed paths).
- B4 (outbox or `verify` container fills the host disk, or `verify` never ends): closed. The
  outbox is its own size-limited volume (1 GB), not a directory on the host filesystem; `verify`
  runs with memory, process-count, writable-layer and wall-clock limits and is killed at the
  limit.
- B5 (a detached loop or an edited scheduler config outlives `maxActive` and the timeout):
  accepted residual, bounded. J7 is a convenience, not a control. The bound is R-KEY's daily
  request budget and the workspace's monthly cap, on a workspace no attended session uses.
- B6 (DNS as an outbound channel): closed by R-KEY (no secret to send, no direct DNS).
- B7 (bundle fetch fails when the quarantine repository's develop is older than the bundle's
  base): closed. `show` fetches `refs/heads/develop` from GitHub first, then the bundle; a bundle
  whose prerequisites are still missing is reported as "not based on origin/develop" and refused.
- B8 (no rebase warning; the push skips `git-hooks/pre-push`'s overlap refusal and lint): closed
  for the overlap. `show` lists every path changed both by the branch and by develop since the
  merge base, and `push` refuses while that list is non-empty. The pre-push lint is not run at
  intake (it would run tools over agent files as the owner); `merge-pr.sh`'s gauntlet lints after
  approval.
- B9 (gauntlet cannot pass as root): closed. J1 and I5 require a non-root user in both
  containers.
- B10 (the run cannot read a GitHub issue): closed. The task prompt carries the issue text, put
  there by the owner's scheduler entry; `api.github.com` stays off the allowlist.
- B11 (`test-integrity` denies a legitimate assertion edit through Edit, and a Bash rewrite goes
  around it): accepted residual, as J6 already says. The gate is a mistake-catcher inside the
  jail, not a control; the control is the owner's reading of the diff.
- B12 (`transfer.fsckObjects` is not applied to a bundle fetch; a `.git` tree entry was stored):
  closed by R-SHAPE's explicit `git fsck --strict`. V1 was false as written.
- B13 (a tag named `origin/develop` shadows the base, so the diff reads empty or partial): closed
  by R-GIT (`--no-tags`, full ref names) and R-SHAPE's ref-list check.
- B14 (an outbox file named like a git option or an scp-style host runs a command or opens an ssh
  connection as the owner): closed by R-NAME and R-GIT (absolute path after `--`).
- B15 (a small bundle expands to gigabytes of diff): closed by R-SHAPE's size checks, which run
  on object sizes before any diff or scan.
- B16 (`list` prints a file name holding terminal escapes): closed by R-NAME and R-FILTER.
- B17 (C1 and format characters in commit messages and paths pass the filter): closed by
  R-FILTER and R-GIT (`core.quotePath=true`).
- B18 (a criss-cross merge makes the three-dot diff hide a removed line): closed by R-SHAPE; a
  branch with a merge commit or more than one merge base is refused.
- B19 (a rename moves a test out of the judge paths with no flag and no removed line): closed by
  R-GIT (`--no-renames`), and `show` lists every deleted path.
- B20 (the judge-path list misses `skills/*/scripts/*`, `.mcp.json`, nested `CLAUDE.md`,
  `AGENTS.md`, `.gitignore`): the list is **dropped**. `show` instead labels a change "inert"
  only when every changed path is a `.md` file under `docs/` whose basename is not `CLAUDE.md`,
  `CLAUDE.local.md` or `AGENTS.md`, or is `README.md`, `CHANGELOG.md`, `LICENSE` or `NOTICE`.
  Any other change is labelled "runs or instructs: read every line". No path is treated as safe
  because a list omitted it.
- B21 (the secret scan is dodged by an allow marker, a split or an encoding): the scan is
  **demoted** to an aid. With R-KEY no secret exists in the jail; `show` also flags any added
  line holding `gitleaks:allow` or `pragma: allowlist secret`.
- B22 (invisible Unicode tag characters carry instructions to the attended review session):
  closed at intake by R-SHAPE (non-ASCII in added lines or paths refuses the push by default).
  Stays open for visible text: see residual 2.
- B23 (a quarantine repository made with `clone --mirror` cannot push a refspec): closed by
  R-GIT.

Residual risks this design does not close:

1. After `push`, the agent's code runs with the owner's privileges in `merge-pr.sh`'s gauntlet.
   The approval is the control. An owner who pushes without reading has no protection.
2. The attended fresh-context review reads agent-written text in plain sight (a comment, a doc
   line, a test name). `merge-pr.sh` checks that a verdict comment exists, not who wrote it. A
   review session with write credentials can be steered by that text. Unchanged from today.
3. A steered run can waste the dedicated workspace's budget up to the daily and monthly limits.
4. Container escape is out of scope: J1 holds as far as the container runtime holds.
5. `--allow-non-ascii` and an overlap override, if the owner uses them, reopen B22 and B8 for
   that one push.

## Revision 2

Validator round 1 confirmed 17 of the 23 breaks closed, left B4, B15, B20 and B22 open, counted
the two accepted residuals (B5, B11) as open, and found two new breaks (N1, N2). Where this
section and anything above disagree, this section wins.

- **R-STAGE (replaces the shared quarantine repository; closes N1, and B12 again).** Each task
  gets its own staging repository: a fresh `git init --bare` under an owner-only directory,
  filled with `refs/heads/develop` fetched from GitHub, then the bundle. `git fsck --strict
  --no-dangling` runs once before the bundle fetch and once after; the task is refused when the
  second run exits non-zero or prints an `error` or `warning` line the first run did not print.
  `show`, `push` and `verify` work from that task's staging repository only. `drop` removes the
  whole staging repository, so one hostile bundle leaves nothing behind for the next task.
- **R-COPY (closes N2).** Intake never works on a file in the outbox. For a name that passes
  R-NAME it opens the entry relative to the outbox directory handle with no-follow and
  non-blocking flags, checks on the open handle that it is a regular file, and reads at most the
  size cap from that handle into an owner-only directory. Every later step reads the copy.
- B4, closed: `verify` runs the container with logging to the host switched off; the gauntlet's
  output goes to a file on the container's own size-limited volume, and the host reads only the
  last 8 KB of that file, by bytes, after the container has stopped.
- B15, closed: before any blob content is read, `show` takes the tree-level change list
  (`git diff --no-renames --raw`, which reads no blob content) and refuses when it has more than
  300 entries, or when the sizes of the new-side blobs, **counted once per path**, total more
  than 20 MB, or any one is over 1 MB. Every later content-reading step runs under a wall-clock
  limit and a byte cap on its output.
- B20: the "inert" label is **dropped**. The first replacement (a judge-path list) and the second
  (an inert list) each missed a file that steers sessions (`docs/METHODOLOGY.md`, which a
  SessionStart hook injects whole). `show` prints the changed paths and labels nothing as safe.
- B22, closed, and the non-ASCII rule narrowed: R-SHAPE's refusal now covers added lines, paths,
  commit messages, and author and committer names and addresses, and it refuses only invisible or
  control code points: Unicode categories Cc (except newline, tab, and a carriage return directly
  before a newline), Cf, Cs, Co, Cn, Zl and Zp. Visible non-ASCII text (letters, punctuation,
  symbols) is allowed, so ordinary commits are not refused; R-FILTER still prints every
  non-ASCII code point as a visible escape in `show`'s own output. The override flag is renamed
  `--allow-invisible`.
- R-KEY, tightened on the validator's notes: the forwarding proxy sends only to the fixed host
  `api.anthropic.com`, accepts origin-form request targets only, matches the two paths exactly
  (a query string is allowed, a longer path such as `/v1/messages/batches` is not), parses the
  body as JSON and rejects a top-level `mcp_servers` key or a `tools` entry whose `type` is a
  server-side tool (a substring match is not used), and budgets by the token usage each response
  reports, not by request count. The read proxy checks its allowlist before resolving a name.
- B5 and B11 stay accepted residuals, as in revision 1.

Residual 5 now reads: `--allow-invisible` and the overlap override, if the owner uses them,
reopen B22 and B8 for that one push. A new residual 6: look-alike visible characters (a Cyrillic
letter in an identifier) are allowed and shown only as escapes in `show`.

## Revision 3

Validator round 2 confirmed B4, B15, B20, B22, N1 and N2 closed and found three new breaks
(N3 delta bomb, N4 invisible characters outside the refused categories, N5 the `verify` log read).
All three share one cause: the owner's own processes still parse or read agent-made bytes with no
resource limit and no single reading rule. Revision 3 changes the structure instead of adding a
third patch to each. Where this section and anything above disagree, this section wins.

- **R-BOX (closes N3; replaces where R-STAGE and R-SHAPE run).** Every step that parses the
  bundle runs inside a throwaway **intake container**: no network, a non-root user, hard memory,
  process-count and wall-clock limits, its only writable storage a size-limited staging volume.
  Inside it, the base branch's `agent-intake` checks run in this order: fetch `develop` objects
  from a read-only mount of the owner's quarantine mirror (the container has no network), fetch
  the copied bundle, read every new object's size with `git cat-file --batch-check` (object
  headers only; refuse on the 1 MB and 20 MB limits and on more than 5,000 new objects), then
  `git fsck --strict --no-dangling` before and after as in R-STAGE, then the R-SHAPE checks and
  the 300-entry cap, then write a text report and the diff to the staging volume. A container
  killed by a limit is a refusal. The host never runs `index-pack`, `fsck` or `diff` on a bundle.
- **R-READ (closes N5; extends R-COPY).** Everything the host reads that a container or the jail
  could have written goes through one function: open relative to a directory handle with
  no-follow and non-blocking flags, check on the open handle that it is a regular file with one
  link, read at most a byte cap, then R-FILTER. This covers outbox entries, the intake
  container's report and diff, and the `verify` container's log. The outbox and staging volumes
  are mounted with no device files, no set-uid and no execute permission. `drop` removes outbox
  entries by name without following links, and keeps only the R-READ copy.
- **Push after R-BOX.** `push <task> <sha>` runs on the host, with R-GIT's pinned configuration,
  from the staging repository the intake container wrote, and only when that container's report
  ended in "accepted" for the same commit id. Every object in it has already passed the size,
  count and fsck checks inside the container.
- **N4 and B22, third form.** Two rules, no category arithmetic:
  1. Commit messages, author and committer names and addresses, and paths: printable ASCII,
     newline and tab only. No override. The run is told this in its task prompt.
  2. Added lines: a code point outside printable ASCII, newline and tab is allowed only when
     that same code point already appears in a tracked file of `refs/remotes/origin/develop` and
     is not on a fixed invisible list (the categories of revision 2, all variation selectors,
     U+034F, U+115F, U+1160, U+17B4, U+17B5, U+2800, U+3164, U+FFA0). Anything else refuses, with
     the override `--allow-invisible` for that one push.
  `show` also prints, per file, how many non-ASCII code points the added lines hold, and R-FILTER
  still prints each one as a visible escape. This is an aid to the owner's reading, not a proof:
  see residual 2, which already says visible agent text can steer the review session.
- **Leftovers the validator named.** I5's sentence about judge paths is replaced by: `verify`
  always prints "advice only: the commit's own code ran these tests". Revision 1's size check
  over all new objects is kept (it is the `--batch-check` step above), so a large blob added in
  one commit and removed in a later one is counted. I4 is replaced by R-READ's `drop`.

Residuals after revision 3: 1 to 4 and 6 as before. Residual 5 now names only `--allow-invisible`
and the overlap override. New residual 7: R-BOX and `verify` hold only as far as the container
runtime's limits hold, and none of the container behaviour in this proposal has been run (no
Docker daemon was available to the author or the validators).
