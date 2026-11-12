# Proposal: jailed unattended agents that can write only `agent/**` branches (version 4)

> **Status (2026-11-12): NO-GO, not built.** This is the working file of an `mh:attack-proposal`
> run, kept as a record. Three attack lanes found 17 breaks in the first text; three validator
> rounds then closed them or accepted them as residuals (the final list is at the end of
> `## Revision 3`), and each found 1 or 2 new ones, and the skill stops at three
> rounds. The two breaks open at the end (a rename on `develop` moving an agent edit to another
> path at sync time, and the owner-login comparison being case-sensitive) have a proposed fix
> each, named in the last validator's report and **not** written into this file or checked.
> Every attacker and validator was Claude (no Codex in the session, so independence was reduced),
> round 1's output did not go through the mechanical verdict and citation checkers, and nothing
> about containers, the ruleset or the deploy key was run against GitHub or Docker. The final
> residual list is at the end of `## Revision 3`. Read later sections as overriding earlier ones.
> A script for testing the GitHub-side facts on a throwaway repository sits beside this file
> (`unattended-jail-branch-key-proposal-2026-11-12.probe-branch-key.sh`); it has not been run
> against GitHub. The design before this one is `unattended-jail-intake-bundle-proposal-2026-11-12.md`.

Fourth design for unattended Claude Code runs on `wasikarn/method-harness` (the `mh` plugin; a
public repository on a personal GitHub account, no CI, no `.github/` directory, merges done by
`scripts/merge-pr.sh` on the owner's machine). Version 3 (jail plus an owner-side intake script
that read a git bundle) failed three validator rounds: every round found a new way for
agent-made bytes to hurt the owner-side parser. Its jail half held. Version 4 keeps the jail and
removes the owner-side parser: GitHub receives, checks and displays the agent's work.

## The problem

Scheduled runs (`claude -p ... --permission-mode bypassPermissions`, launched by
`agent-autoloop`) read untrusted text and can be steered by it. They must be able to deliver
work for the owner to approve, without holding anything that can change the protected branch,
speak as the owner on GitHub, or reach the owner's files, and without the owner's machine parsing
agent-made bytes before the owner has decided to take them.

## The change

### Principle

The run can do exactly one thing outside its jail: create and update branches named `agent/**`
on the repository. It cannot read the credential that lets it do so. Everything it pushes is
received and rendered by GitHub. The owner approves by copying one commit into the owner's own
branch namespace through the GitHub API, which the run cannot write, and from there the existing
attended flow applies unchanged.

### J. The jail (kept from version 3, as revised)

- J1. A dedicated container or VM, non-root user. Nothing of the owner's is mounted: no home
  directory, no `~/.claude`, no Docker socket, no keychain.
- J2. No GitHub token, no `gh` login, no credential helper, and **no key file** in the jail.
- J3. No Anthropic key in the jail. A forwarding proxy outside the jail holds a workspace-scoped
  key of a dedicated Console workspace; `ANTHROPIC_BASE_URL` points at it. It sends only to
  `api.anthropic.com`, accepts origin-form targets, matches `POST /v1/messages` and
  `POST /v1/messages/count_tokens` exactly (query string allowed), parses the body as JSON and
  rejects a top-level `mcp_servers` key or a server-side tool in `tools`, and budgets by reported
  token usage per day.
- J4. Egress only through that forwarder and a filtering proxy that allows anonymous HTTPS reads
  of `github.com` and `codeload.github.com`, the package registries the gauntlet needs, and SSH
  to `github.com` (port 22, or `ssh.github.com` port 443). The proxy checks its allowlist before
  resolving a name. No direct DNS, no host loopback, no LAN.
- J5. `agent-autoloop` runs inside the jail. Its cards are notification only.
- J6. `mh` is installed in the jail unchanged; a gate that stops the run is reported in the run's
  hand-off commit message. No gate is weakened.
- J7. One run at a time and a timeout are conveniences, not controls; the spend bound is J3's
  daily budget and the workspace's monthly cap.

### K. The branch key (the one capability)

- K1. A **deploy key** with write access is added to the repository. A deploy key is an SSH key
  bound to this one repository; it can run git operations over SSH and has no access to the
  GitHub API (no pull requests, comments, reviews, commit statuses, releases, settings).
- K2. The private key never enters the jail. An `ssh-agent` process outside the jail holds it,
  and only that agent's socket is mounted into the jail (`SSH_AUTH_SOCK`). The run can ask the
  agent to sign, so it can push while it is running; it cannot copy the key out.
- K3. A repository **ruleset** limits what any non-admin can write: for every branch whose name
  does not match `agent/**`, and for every tag, creation, update and deletion are restricted,
  with only the repository admin role on the bypass list. `develop` keeps its existing protection
  (pull request required, `mh/gauntlet` status on an up-to-date head). So the deploy key can
  create, move, force-move and delete `agent/**` branches, and nothing else.
- K4. GitHub Actions is disabled for the repository in its settings, and stays disabled.
  (A branch could otherwise add a workflow file that runs with a repository token on push.)

### H. The hand-off

- H1. The run commits in its jail clone and pushes to `agent/<task>` over SSH. The commit message
  of the tip commit is the hand-off note.
- H2. The owner learns of it from GitHub (the branches page), or from a small poller on the
  owner's side that runs `git ls-remote origin 'refs/heads/agent/*'` and prints branch names and
  commit ids through a filter that shows every byte outside printable ASCII as an escape. The
  poller downloads no objects.

### A. Approval

- A1. The owner opens the comparison `develop...agent/<task>` on github.com and reads it there.
  GitHub's own rendering applies (hidden bidirectional characters are flagged, binary files are
  not rendered).
- A2. To take a commit, the owner **freezes** it: one GitHub API call from the owner's account
  creates `refs/heads/claude/agent-<task>` at the commit id the owner read
  (`gh api repos/wasikarn/method-harness/git/refs -f ref=refs/heads/claude/agent-<task> -f sha=<id>`).
  No object is downloaded to the owner's machine for this. The deploy key cannot move or delete
  `claude/**` (K3), so what the owner froze cannot change afterwards.
- A3. The owner opens the pull request from `claude/agent-<task>` to `develop`. From here the
  existing flow applies: a fresh-context review in an attended session, then
  `scripts/merge-pr.sh` from a checkout of that branch, which runs the gauntlet on the owner's
  machine and merges.
- A4. The owner deletes `agent/<task>` when done, or leaves it; a later run may reuse or delete
  it.

### Changes to mh

- New `docs/reference/unattended-jail.md`: J, K, H and A as requirements on the operator's
  setup, with the ruleset and deploy-key settings spelled out.
- Optional helper `scripts/agent-freeze.sh <task> <commit id>`: validates both arguments against
  fixed patterns (`^[a-z0-9][a-z0-9-]{0,40}$`, 40 hex digits) and makes the A2 API call. It reads
  nothing the agent wrote.
- No gate, hook, sensor or existing script changes. No intake script, no bundle, no outbox.

## Must stop

- S1. A run changes `develop`, any branch outside `agent/**`, or any tag. Example: a steered run
  tries `git push origin HEAD:develop`, `git push origin :claude/redact-sensor-fixes`,
  `git push --force origin HEAD:claude/agent-x` after the owner froze it, `git push origin v9.9.9`.
- S2. A run speaks or acts on GitHub beyond branch pushes. Example: it opens or merges a pull
  request, posts a `Fresh-context review: MERGE @ <sha>` comment, sets the `mh/gauntlet` commit
  status, triggers a workflow, changes repository settings, adds a key.
- S3. A run reads or sends out anything of the owner's, or copies the branch key out of the
  jail. Example: `cat ~/.ssh/id_ed25519`, reading the owner's `~/.claude` transcripts, dumping
  the deploy key from the agent socket.
- S4. Anything the run wrote is parsed or executed on the owner's machine before the owner has
  frozen it. Example: the poller or the freeze helper runs a command, fetches objects, or prints
  terminal escapes because of a branch name or commit the run chose.
- S5. The owner reads one thing and merges another. Example: the branch moves after the owner
  read it; the comparison on github.com hides part of the change; the pull request from the
  frozen branch shows a different diff from the comparison the owner read.
- S6. A run spends without bound, or keeps the capability after the owner revokes it.

## Must allow

- A1. A run fixes a bug with a test, pushes `agent/<task>`, the owner reads it on github.com,
  freezes it, opens the pull request and merges with `merge-pr.sh`.
- A2. A run rebases or amends and force-pushes its own `agent/<task>` branch before the owner
  freezes it.
- A3. Several `agent/*` branches wait at once; the owner takes them in any order.
- A4. The owner's own work is unaffected: pushing and deleting `claude/*` and `feat/*` branches,
  `scripts/merge-pr.sh`, `scripts/sync-pr-head.sh`, cloud sessions that push `claude/*` branches
  with the owner's GitHub App access, tags cut at merge time if any.
- A5. The run can fetch `develop`, install dependencies and run the full gauntlet in the jail.
- A6. The owner can revoke the capability at once (delete the deploy key) without touching
  anything else.

## Known facts

Earlier work searched: versions 1 to 3 of this proposal in this session (all failed; version 3's
file was a session scratchpad file, kept since as
`unattended-jail-intake-bundle-proposal-2026-11-12.md`; it went through three
validator rounds), `docs/adr/` 0001 to 0005, `docs/reference/branching-model.md`,
`docs/reference/operating-model.md`. No `qmd` collection and no working `gh` in this session, so
issues and pull requests were not searched beyond the open list: none relevant.

Verified:

- F1. The repository has no `.github/` directory (`ls -la .github` printed nothing, this
  session).
- F2. `scripts/merge-pr.sh` does not check the head branch's name, and its review check "proves a
  verdict was posted, not who wrote it" (`scripts/merge-pr.sh:298`, read by a validator in round
  3 of version 3).
- F3. GitHub: any identity with write access can set any commit status through the API; push
  restrictions and bypass lists in classic branch protection are organization-only (docs, round
  1 of version 1).
- F4. With no secret in the jail and the API key behind a forwarding proxy, three attack lanes
  and three validators found no way for a jailed run to reach the owner's files, the owner's
  GitHub identity or the key (version 3, revisions 1 to 3). Not run in a real container.
- F5. In a `-p` run a PreToolUse hook's "ask" is a denial (live probe, claude 2.1.322).
- F6. `merge-pr.sh`'s gauntlet runs the pull request's code as the owner (`scripts/merge-pr.sh`
  runs the checkout's `scripts/run-gauntlet.sh`).

**Unverified. These are the first targets:**

- U1. Repository rulesets are available on a public repository owned by a personal account, can
  target "all branches except `agent/**`" and all tags, can restrict creations, updates and
  deletions, and can have a bypass list that holds only the repository admin role.
- U2. A deploy key is bound by those rulesets and by `develop`'s branch protection: it is not an
  admin, it cannot be a hidden bypass actor, and a push it makes to a restricted ref is refused.
- U3. A deploy key has no GitHub API access of any kind, and no git-over-SSH operation lets it
  create a pull request, a comment, a status, a release, a wiki page, a gist, or a Pages build.
- U4. With Actions disabled in repository settings, a pushed workflow file does nothing, and no
  other automatic GitHub feature acts on an `agent/**` push with elevated rights (Dependabot,
  Pages, code scanning defaults, installed GitHub Apps such as the Claude app, webhooks).
- U5. A mounted `ssh-agent` socket lets the jail sign but never read the private key, and the
  agent protocol gives the jail nothing else of value (adding keys, locking the agent, or using
  other keys loaded in the same agent).
- U6. Creating a ref through the API at a commit that exists only on an `agent/**` branch works,
  downloads nothing to the owner's machine, and the frozen ref cannot be moved or deleted by the
  deploy key.
- U7. The comparison view on github.com shows everything the pull request from the frozen branch
  will merge: no merge-base trick, rename, large-diff truncation, generated-file collapsing,
  `.gitattributes` setting (`linguist-generated`, `-diff`, `binary`), whitespace or
  hidden-character case makes the owner read less than what merges.
- U8. `git ls-remote` on the owner's machine, printing only names and ids through the filter, is
  safe against any ref name the deploy key can create, and downloads no objects.
- U9. The owner's existing flows keep working under the ruleset: `merge-pr.sh` and
  `sync-pr-head.sh` push with the owner's account (admin, bypass), and cloud sessions that push
  `claude/*` branches through the Claude GitHub App are not blocked by it.
- U10. Deleting the deploy key cuts the capability at once, including for an SSH connection that
  is already open.
- U11. Nothing an `agent/**` branch can contain changes what github.com does for other users of
  the repository (the default branch stays `develop`; the README, licence, security policy,
  funding file and plugin marketplace manifest are read from the default branch only), and a
  plugin user cannot be made to install from an `agent/**` branch without choosing it.

## What version 3 got wrong, and what version 4 claims instead

Treat each claim as something to break.

| Version 3 break | Version 4's claim |
|---|---|
| Owner-side `git fetch`, `fsck`, `diff` on a hostile bundle (option injection, tag shadow, delta bomb, path bomb) | The owner's machine downloads no agent object before freezing; GitHub receives and stores the push |
| Custom diff display (control characters, invisible Unicode, binary files hiding text) | The owner reads on github.com; no custom renderer |
| Outbox races, symlinks, disk fill | No outbox |
| Host `git push` from a repository a container wrote | The freeze is one API call naming a commit id |
| Judge-path and "inert" lists that kept missing files | No list; the owner reads the comparison |
| Bundle replaced between `show` and `push` | The owner freezes a commit id into a namespace the key cannot write |

Residual risks stated up front:

1. After the owner opens the pull request and runs `merge-pr.sh`, the agent's code runs with the
   owner's privileges in the gauntlet. Freezing is the owner's statement that the diff is
   acceptable to run.
2. The attended fresh-context review reads agent-written text, and `merge-pr.sh` does not check
   who wrote the verdict comment. A review session with write credentials can be steered.
3. A steered run can publish arbitrary content on public `agent/**` branches of the owner's
   repository until the owner deletes the branches or the key, and can waste the dedicated API
   budget up to its limits.
4. Container escape, and bugs in GitHub's own enforcement, are out of scope.

## Revision 1

Round 1 ran three attack lanes and returned 18 breaks (two lanes reported the same fetch break,
so 17 distinct). GitHub's own documentation confirmed U1, U3 and the Actions half of U4, and
showed that "deploy keys" is not a bypass actor on github.com. The author reproduced C1 and its
fix. Where this section and the text above disagree, this section wins. One line per break:
closed how, dropped, or accepted as a stated residual.

Design changes several closes share:

- **R-REFSPEC.** Every clone the owner works in carries a negative fetch refspec,
  `git config --add remote.origin.fetch '^refs/heads/agent/*'`, so an ordinary `git fetch origin`
  (which `scripts/merge-pr.sh:76` runs first for every pull request) never downloads an
  `agent/*` branch. A new harness-audit check warns when the checkout's `remote.origin.fetch`
  lacks it. The claim "the owner's machine downloads no agent object before freezing" now holds
  only for clones that carry this setting; a fresh clone without it (a cloud session, a new
  machine) does download them. Those objects come from GitHub's own pack generation after
  GitHub's receive checks, not from an agent-written pack file, and nothing checks them out.
- **R-FREEZE (replaces the optional helper with a required one, `scripts/agent-freeze.sh`).**
  It talks only to the GitHub API with the owner's `gh` login and downloads no git objects.
  - `agent-freeze.sh show <task>`: reads the current tip id of `agent/<task>`, calls the compare
    API for `develop...<id>`, and **refuses** unless: every commit in the comparison has exactly
    one parent; the merge base is a commit on `develop`; fewer than 300 files changed; no changed
    path is `.gitattributes`, `.lfsconfig`, `.gitmodules` or under `.github/`; and the
    repository's Actions setting reads disabled. It prints the tip id and a comparison URL that
    names that id, not the branch. Everything it prints from the API passes a filter that shows
    bytes outside printable ASCII as escapes. It prints no commit message.
  - `agent-freeze.sh take <task> <id>`: refuses unless `<id>` is still the current tip of
    `agent/<task>` and passes the same checks again, then creates `refs/heads/claude/agent-<task>`
    at `<id>`.
  The owner reads the comparison at the id-pinned URL between the two commands.
- **R-AGENT.** The key is held by a dedicated `ssh-agent` that holds nothing else, running in a
  small sidecar container as the same numeric user as the jail's user, with its socket on a
  volume shared only with the jail. The owner's own agent socket (including Docker Desktop's
  `/run/host-services/ssh-auth.sock`) is never mounted. The key is loaded with a destination
  constraint for `github.com`. The sidecar is started fresh, and the key reloaded, at the start
  of every run.
- **R-VERDICT (a change to an existing script).** `scripts/merge-pr.sh` counts a
  `Fresh-context review` verdict comment only when its author is the repository owner's login.
  Built test-first.

Per break:

- C1 (an ordinary `git fetch origin` downloads every `agent/*` branch before any freeze; up to
  GitHub's push limits on many branches): closed for the owner's working clones by R-REFSPEC;
  accepted residual for clones that lack the setting.
- C2 (`agent/a` deleted and `agent/a/b` pushed makes every later `git fetch origin` fail, so
  `merge-pr.sh` dies for every pull request): closed twice. R-REFSPEC keeps `agent/*` out of the
  fetch, and the ruleset pattern `agent/**` matches one path level only (GitHub documents
  `File::FNM_PATHNAME`), so the key cannot create `agent/a/b` at all.
- C3 (the frozen branch's own `git-hooks/` run at `git checkout`, and inside `merge-pr.sh`'s
  commit and push, before the gauntlet): accepted, and residual 1 is corrected: the agent's code
  runs with the owner's privileges **from the first checkout of the frozen branch**, not from the
  gauntlet. This already holds for any pull request today.
- C4 (a criss-cross merge makes `develop...agent/x` show nothing while the real merge removes a
  line): closed by R-FREEZE (single-parent commits only, merge base on `develop`).
- C5 (more than 300 files, or `linguist-generated` in the branch's `.gitattributes`, hides part
  of the diff on github.com): closed by R-FREEZE (file count, `.gitattributes` refused).
- C6 (the helper froze any 40-hex id, including one the note suggested): closed by R-FREEZE
  (`take` accepts only the current tip, and `show` prints no agent text).
- C7 (`.lfsconfig` plus an LFS pointer makes the owner's checkout call an agent-chosen host):
  closed by R-FREEZE (`.lfsconfig` and `.gitattributes` refused).
- C8 (any GitHub account can post the `MERGE` verdict comment on a public pull request):
  closed by R-VERDICT.
- C9 (the repo's doctrine says to re-add a workflow; with Actions enabled a workflow file on an
  `agent/*` branch runs with a repository token): closed by R-FREEZE's Actions check and an edit
  to `docs/reference/branching-model.md` saying Actions must stay disabled while a write deploy
  key exists. Between the moment Actions is enabled and the next `show`, the hole is open.
- C10 (content that breaks GitHub's acceptable-use rules, pushed to public `agent/*` branches
  with the owner's address as author, can get the owner's account suspended; pushed commits stay
  reachable by id after the branch is deleted): accepted residual, added to residual 3. Nothing
  in this design prevents it. This is the price of letting an unattended run publish anything.
- C11 (the mounted agent is the owner's own, so the jail can use the owner's personal key):
  closed by R-AGENT.
- C12 (a run locks the agent or removes the key, blocking later runs): closed by R-AGENT (fresh
  sidecar per run); within one run it is self-inflicted.
- C13 (a jail user whose numeric id differs from the agent's is refused by the agent): closed by
  R-AGENT (same numeric user).
- C14 and C15 (`git commit --amend` and the short force-push forms are denied by mh's gate in an
  unattended run): accepted, and Must-allow A2 is narrowed: the run updates its branch with new
  commits, or after `git rebase origin/develop` with the one force form the gate allows,
  `git push --force-with-lease origin HEAD:agent/<task>` as a single command. The task prompt
  says so.
- C16 (URL-sourced image and document blocks make Anthropic's servers fetch an agent-chosen
  address): closed. The forwarding proxy also rejects any content block whose `source.type` is
  `url`.
- C17 (an aborted streaming request reports almost no usage, so the daily budget undercounts):
  closed. The proxy caps `max_tokens`, and charges each request up front with its `max_tokens`
  plus an estimate from the request size, before forwarding.

Still unverified after round 1, all on the GitHub side and none answerable without the owner's
account: whether pushes and merges made through the Claude GitHub App count as the repository
admin role under the ruleset (U9: if not, cloud sessions can no longer push `claude/*`); whether
a deploy key can push refs outside `refs/heads` and `refs/tags`, write the wiki, or use Git LFS;
whether deleting a deploy key ends an open SSH session (U10); whether the refs API will create a
branch at a commit that is no longer on any branch (U6).

Residual risks after revision 1:

1. From the first checkout of the frozen branch, the agent's code runs with the owner's
   privileges (hooks at checkout, then `merge-pr.sh`'s commit, push and gauntlet). Freezing is
   the owner's statement that the diff is acceptable to run.
2. The attended fresh-context review reads agent-written text with the owner's credentials and
   can be steered by it. R-VERDICT stops outsiders, not a steered owner session.
3. A steered run can publish anything on public `agent/*` branches under the owner's repository
   and address, which can bring GitHub enforcement against the owner's account; pushed commits
   outlive branch deletion. It can also waste the dedicated API budget up to its limits.
4. Container escape, and bugs in GitHub's enforcement, are out of scope.
5. A clone without R-REFSPEC downloads agent branches on fetch (disk and bandwidth, up to
   GitHub's push limits).

## Revision 2

Validator round 1 confirmed 13 of 17 breaks closed or plainly accepted, left C4, C5, C8 and C9
open, and found one new break (N1). It also confirmed from the public API that the owner's own
sessions, local and through the Claude GitHub App, post as the owner's login. Where this section
and anything above disagree, this section wins.

- C4, closed: `agent-freeze.sh` refuses when the compare response's `total_commits` is more than
  250 or differs from the number of commits it received, so no commit can sit outside what it
  checked. The "merge base is on develop" check is removed (it was always true); the
  single-parent rule over every commit is the check.
- C5, narrowed and partly accepted: the helper refuses a change whose `filename` or
  `previous_filename` has the basename `.gitattributes`, `.lfsconfig` or `.gitmodules` at any
  depth, or lies under `.github/`, and refuses any changed file for which the API returns no
  `patch` (binary or too large to render). It then prints every changed path with its added and
  deleted line counts and the totals. It does **not** claim github.com shows every one of them
  expanded: GitHub collapses files it judges generated by their content, and no list of those
  rules is kept here. New residual 6 says so, and Must-stop S5's last example is withdrawn.
- C8, closed: R-VERDICT applies to both ways `merge-pr.sh` reads comments. On the `gh` path it
  compares each comment's `user.login` with the repository owner before picking the last
  verdict. On the `--verify` path the input contract changes to objects with `body` and
  `user.login`; an entry with no author is not counted.
- C9, restated as a precondition and a residual: K4 (Actions disabled) is a condition S2 depends
  on, not something this design enforces. While Actions is enabled, a workflow file on an
  `agent/*` branch runs on that branch's next push with a repository token, and S2 does not hold.
  The helper refuses to freeze while Actions is enabled, and `docs/reference/branching-model.md`
  is edited to say a workflow must not be re-added while a write deploy key exists; neither stops
  the workflow itself. Listed as residual 7.
- N1, closed for this repository's cloud sessions: `.claude/hooks/session-start.sh` (which
  already sets `core.hooksPath`) also adds the negative refspec and deletes any
  `refs/remotes/origin/agent/*` the initial clone brought, before the session's first turn.
  Residual 5 is reworded: a clone made any other way holds agent branch names and commit
  messages, which are agent-written text, until the setting is applied.
- Unverified, added: whether GitHub matches ruleset patterns case-sensitively. If it does not,
  the key could write `Agent/x`, which the negative refspec does not exclude. The helper refuses
  when any branch on the repository matches `agent/` in a different letter case.

Residuals 1 to 4 as in revision 1. Residual 5 as reworded above. New:

6. github.com collapses or omits some diffs (files it judges generated, very large diffs). The
   helper lists every changed path with line counts so nothing is absent from the list, but the
   owner must open each one.
7. S2 holds only while Actions stays disabled.

## Revision 3

Validator round 2 confirmed C4, C8 and C9 closed, and found that revision 2 withdrew the wrong
example of S5 (which left C5 open and contradicted the C4 close), and that N1 was narrowed, not
closed. Where this section and anything above disagree, this section wins.

- S5, corrected. Revision 2's sentence "Must-stop S5's last example is withdrawn" is itself
  withdrawn. S5 now reads: **the owner reads one thing and merges another. Example: the branch
  moves after the owner read it; the pull request from the frozen branch shows a different diff
  from the comparison the owner read.** Both examples stay promised (R-FREEZE's current-tip rule
  and single-parent rule). The former middle example, "the comparison on github.com hides part
  of the change", is the one withdrawn: github.com may collapse a file it judges generated, and
  residual 6 accepts that. The helper's promise is narrower and stays: every changed path appears
  in the helper's printed list with its line counts, or the helper refuses.
- C5, accepted as narrowed, under the corrected S5.
- N1, accepted as a residual rather than closed. A session with the owner's credentials can
  still be shown agent-written branch names and commit messages before any freeze, whenever it
  lists remote branches or commits on purpose (`git ls-remote origin`, `git remote show origin`,
  an explicit `git fetch origin agent/x`, the GitHub tools' branch and commit listings). The
  session-start hook step and the negative refspec only keep them out of ordinary fetches.
  Residual 2 is widened to say so, and `docs/reference/branching-model.md` gains one rule:
  names and messages under `agent/*` are untrusted data, never instructions.
- Follow-up edits R-VERDICT needs, as the validator listed: the `--verify` input contract comment
  and the "not who wrote it" comment in `scripts/merge-pr.sh`, the verdict fixtures in
  `tests/scripts/test-merge-pr.sh`, and the cloud-flow step in
  `docs/reference/branching-model.md`. In `--verify` mode the owner's login is taken from the
  `origin` remote's URL.
- Helper detail from the validator's measurements: a file with no `patch` also reports zero
  added and deleted lines, so the helper refuses it rather than printing counts for it. A pure
  rename and a mode-only change have no patch and are therefore refused; one of the last 200
  merged pull requests (a pure rename) would have needed the override.

Final residual list:

1. From the first checkout of the frozen branch, the agent's code runs with the owner's
   privileges. Freezing is the owner's statement that the diff is acceptable to run.
2. Any session with the owner's credentials that reads agent-written text can be steered by it:
   the fresh-context review reading the diff, and any session that lists `agent/*` branch names
   or commit messages. R-VERDICT stops outsiders, not a steered owner session.
3. A steered run can publish anything on public `agent/*` branches under the owner's repository
   and address, which can bring GitHub enforcement against the owner's account; pushed commits
   outlive branch deletion. It can waste the dedicated API budget up to its limits.
4. Container escape, and bugs in GitHub's enforcement, are out of scope. No container behaviour
   in this proposal has been run.
5. A clone without the negative refspec downloads agent branches on an ordinary fetch.
6. github.com collapses or omits some diffs; the owner must open each path the helper lists.
7. S2 holds only while Actions stays disabled.
8. Unverified on the GitHub side, answerable only with the owner's account: whether Claude GitHub
   App pushes count as repository admin under the ruleset; whether a deploy key can push refs
   outside branches and tags, write the wiki or use LFS; whether ruleset patterns ignore letter
   case; whether deleting the key ends an open SSH session.
