# Branching model

`develop` is protected (2026-09-28, Phase B of the SDLC-playbook reversal): no direct push, PR
required. Work on a `feat/<slug>` or `claude/<slug>` branch, `gh pr create` against `develop`,
review via the already-installed `mattpocock-skills:code-review` (verified installed:
`skills/engineering/code-review` in the `mattpocock-skills` plugin cache) — this repo does not
rebuild that flow as its own skill (composer-not-creator,
`docs/reference/composer-not-creator.md`). Merge method: merge-commit or rebase, never squash —
a squashed feature branch is not merged by ancestry, so only `git branch -D` removes it locally
(the gate allowed that only from 2026-09-30, for a plain `git branch -D <names>` without main/master/develop).
`delete_branch_on_merge: true` on the remote handles cleanup.

Enforcement layers, weakest to strongest:
- `git-hooks/pre-push` refuses a direct push whose remote ref is `refs/heads/develop`, before
  anything else runs — local, defense-in-depth, one manual retry if a stdin ref line is malformed.
  Then it lints only the pushed files (GH #735); the full gauntlet runs at merge time (below).
  Before opening a PR, `bash scripts/run-gauntlet.sh --level medium --plan develop` runs the tests the
  change can reach (GH #749, levels in `repo-gotchas.md`); it never stands in for the merge-time run.
  It also refuses to *create* a branch that changes a file (not the manifests) `develop` changed since
  the branch point, listing those commits: merge `develop`, check none already makes the change, push
  again (84c57d69 had fixed what #613's first branch re-fixed). Parallel open PRs are not checked.
- `gate:bash:irrecoverable` asks (not denies — a merge can be a legitimate, operator-approved
  action) on `gh pr merge` / `gh api .../merge` from an interactive Claude Code session. This
  covers only a session running with mh loaded — it does **not** constrain the GitHub web UI, a
  raw API call, or any credential used outside such a session (a cloud Routine, notably —
  `docs/adr/0004-operator-authorized-routine-self-launch.md`, `status: proposed`, is where that
  threat model is actually being worked through; mh has no self-launch path shipped today).
- GitHub branch protection on `develop` (PR required, `enforce_admins`, live-applied 2026-09-28;
  required status checks removed 2026-10-03 along with GitHub Actions) enforces the PR flow only; a single-maintainer repo means
  `required_pull_request_reviews.required_approving_review_count` stays at **0** (GitHub refuses to
  let a PR author approve their own PR, so any higher count would make every PR permanently
  unmergeable with only one account) — merging still requires nothing more than a write-access
  credential. "Review" here is this repo's own operating custom, not something
  branch protection mechanically enforces. An admin editing the protection rule itself is a
  separate, named, accepted residual risk, not something any of the above closes.
  There is no CI (2026-10-03): the pre-commit and pre-push hooks and the full gauntlet in
  `merge-pr.sh`/`sync-pr-head.sh` are the only gates, so a clone with `core.hooksPath` unset, or a
  push from another machine, skips the hooks. Re-add a workflow and the
  required contexts together if that stops being acceptable.

## Merging: `scripts/merge-pr.sh <PR>` (GH #450)

#445 and #446 were each green alone and red together on `develop`. Agents merge through
`scripts/merge-pr.sh <PR>`, not bare `gh pr merge`. **PRs do not bump the version; the script does,
at merge time** (2026-10-25: while each PR bumped itself, every peer merge re-conflicted every open PR
on the two manifest lines, and #581 took about six re-sync and gauntlet cycles to land).

Run it from the PR's own checkout, on its branch, with a clean tree (untracked files count), and
start it with `run_in_background`: one run can span a lock wait plus a full gauntlet. Do not edit that
checkout while it runs; it re-checks the tree after each wait and before and after its push, and
refuses on any change. It:

1. refuses unless the PR's base is `develop`, it is not from a fork, the checkout is on the PR's head branch, the tree is
   clean, and the local branch contains the PR head (a rerun after a red gauntlet carries the
   unpushed commits of the last run);
2. checks the review verdict below before writing anything;
3. takes a per-user merge lock (`~/.cache/mh/merge-pr.lock`, the gauntlet queue's code with its own
   dir), so one merge runs at a time and develop holds still during its gauntlet; after 3600 s it
   refuses instead of running unlocked;
4. waits for load below the online core count (`MERGE_PR_LOAD_MAX`), up to 900 s, then fails with the load figure;
5. merges `origin/develop` into the branch when it is behind (the develop tip its own last fetch saw:
   every worktree shares the `origin/develop` ref and peer sessions fetch all the time, so it never
   re-reads the ref between fetches), and writes develop's version + 1 into
   both manifests unless they already agree on a higher one. The sync and the bump are one commit
   (`Merge origin/develop into <branch>; bump mh to N`), or `chore: bump mh to N` when no sync was
   needed. An older PR that still bumps its own version conflicts on that line: when the only
   conflicts are the manifests, the script merges them again with the version set aside, so the
   PR's other manifest edits survive, then keeps the PR's own version if it is higher (a deliberate
   minor bump); any other conflict refuses (merge by hand, push, rerun);
6. runs the full gauntlet (`scripts/run-gauntlet.sh`, under the gauntlet queue) on that exact clean
   tree, or skips it when a pass is cached for the tree (GH #735), then pushes that sha to the PR
   branch when origin does not have it yet (an earlier run pushed it, or an older PR is already up to
   date and above develop). Before the merge call it posts the commit status `mh/gauntlet` =
   `success` on that sha, naming its tree (GH #742), so branch protection can require it; a failed
   post stops the run. A red gauntlet posts none, refuses before any push and leaves the commit on the local
   branch: fix, commit, rerun (a fix commit that touches more than the manifests needs a new review
   verdict). If the tree changed while the gauntlet ran, it refuses. Each run that is not a cached
   pass appends a miss-log row (GH #749: the medium plan beside the full result) to
   `~/.cache/mh/gauntlet-miss.jsonl`; a log failure only prints a note. The push keeps `-o
   ServerAliveInterval=10 -o ServerAliveCountMax=30` on the ssh command (GitHub dropped an idle
   connection during a hook-run gauntlet, exit 141), checks the push by `git ls-remote`, not the exit
   code, and waits for GitHub to show the new head;
7. fetches; if `origin/develop` moved (a merge made outside the script), goes back to step 4, three
   rounds at most;
8. re-checks the version (plain `X.Y.Z`, both manifests equal, above `origin/develop`'s), the review
   and the base, merges with `gh pr merge --merge --match-head-commit <pushed sha>`, and prints the
   merge commit sha.

Never rebase a PR branch: a rebase rewrites every commit and throws away the review verdict below.
On a wrong-base refusal, retarget the PR with `gh pr edit <PR> --base develop`.

It also refuses a PR without a current review verdict (2026-10-25: #569–#576 and #611 merged while
their reviews still said FIX FIRST, and #570 opened a hole that took #602 to close). The verdict is a line
`Fresh-context review: MERGE @ <sha>` (or `FIX FIRST` / `CLOSE`; case and markdown emphasis ignored) in a
PR **comment**, `<sha>` being the head the reviewer read; a GitHub PR review or the PR body does not count,
nor does a line inside a ``` or ~~~ fence at any indentation (closed only by a bare line of the same
character, at least as long), and the last verdict line in a comment wins. The last verdict on
the PR must be `MERGE`, its `<sha>` must be in the head's history, and every commit after it must change only
the two manifests' `"version"` value or be a two-parent merge whose tree is what `git merge-tree --write-tree`
makes of its parents, the manifests' version aside, and whose only conflicts were in the manifests and resolve
the way the script resolves them (GH #629; git >= 2.38, 2.43 for a conflicted manifest), checked before the script writes anything, before its
push and before the merge. `plugin.json` can carry inline hooks and MCP servers, so any other manifest edit
counts as code. So merging `develop` and bumping the version keep the review; any other change (an edit made
inside a merge, or a conflict resolved in code, included), a rebase, or a force-push needs a new one. The
check is bound to the sha, not to timestamps, so a commit made before the review but pushed after it is
still caught. Post the reviewer's result as that comment. It proves a verdict was posted, not who wrote it
or that the reviewer had fresh context. There
is no opt-out variable; an operator who must merge without a verdict does it on GitHub.

**Without `gh` (a Claude Code cloud session).** The script reads the PR and merges through `gh`, which a
cloud session lacks; it has the GitHub MCP tools instead. Do not retype the checks by hand (that was
done for #633, #644 and #648, with nothing to say a check was skipped). Instead:
1. read the PR's head sha, base branch and issue comments with the MCP tools, and save the comments
   to a file. The comments come a page at a time, oldest first: request `perPage` 100 and keep
   reading pages until one comes back short, appending each page's array to the file in order (`jq`
   reads arrays saved one after another, like `gh --paginate` output), and check the total against
   the PR's comment count. A page left out can hide the latest verdict: a FIX FIRST on page 2 after a
   MERGE on page 1;
2. run `scripts/sync-pr-head.sh <head branch> <head sha>` and use the sha it prints, every time: it is
   the cloud path's only full gauntlet (GH #735; a push only lints). When the head lacks
   `origin/develop` or a version above it, it merges develop and bumps in a temporary worktree; either
   way it runs the full gauntlet on the tree that merges (a cached pass skips it), then pushes leased
   on the head when it made a commit. With `gh` on PATH it then posts `mh/gauntlet` = `success` on
   the sha it prints (GH #742; a failed post exits non-zero); without `gh` it says it posted none. A PR from a fork
   (its head repository is not this one) cannot be synced this way, since the sync pushes to a branch
   of `origin`: merge develop into it and bump on the fork by hand;
3. run `scripts/merge-pr.sh --verify <PR> <head sha> <base branch> <comments file>`: the same base,
   review (same verdict parser), ancestry and version checks, never a lock, sync, push or merge. It
   also refuses unless a full-gauntlet pass is cached for the head's tree (GH #735: step 2 writes it,
   or `bash scripts/run-gauntlet.sh` on a clean checkout of that head, in the same session's
   `~/.cache`). On a pass it posts the `mh/gauntlet` status when `gh` is on PATH (a failed post exits
   non-zero), else it says it posted none. Once branch protection requires `mh/gauntlet` (below),
   an MCP-only merge from a session without `gh` is refused: turning that check on stops cloud
   MCP-only merges, so merge such a PR from a machine with `gh`. It prints the head on a pass, and on a head that is not synced or has no
   cached pass it names the command to run;
4. read the PR once more with the MCP tools and confirm its base is still `develop` and its head is
   still that sha (`--verify` only knows the values it was given; the `gh` path re-reads the base
   itself), then merge through the MCP merge tool with `expectedHeadSha` set to that head, straight
   away. If develop moved first, go back to step 2.
There is no load wait and no merge lock in this mode: a cloud container runs nothing else, and the
lock is per machine.

**`mh/gauntlet` branch protection (operator's step, not yet applied; GH #742).** The scripts above
post the commit status `mh/gauntlet` = `success` on a head only after a green or cached full gauntlet.
To make GitHub refuse every merge path without it (web button, bare `gh pr merge`, MCP), the
operator sets two things in develop's branch protection: the required status check context
`mh/gauntlet`, and "Require branches to be up to date before merging" (so the checked head is the
merged tree). The status is an honest-agent signal: any token with repo scope can post it, so it is
not a security boundary.

The checks and the lock are local-only. The script narrows the gap; it does not close it: a merge made
outside the script costs a retry round, a push to `develop` from another clone between the last check
and the merge can still race, and nothing stops a merge made outside the script. The script's own `gh pr merge` call runs inside the script, so
`gate:bash:irrecoverable`'s ask on that command does not see it.

The former `git worktree add -b` deny predates this and was removed in the v1.0.0 rebuild;
`claude --worktree` and `/branch` never routed through it anyway. `/branch` and
`claude --continue --fork-session` are session branches, not git branches: they fork the
conversation without touching the working tree.

**Never run upstream's `git-guardrails-claude-code` setup here** (`skills/misc/` in
mattpocock/skills, not in the plugin's skills list). It wires a PreToolUse
hook blocking *all* `git push`, not just `--force`. `gate:write:config-guard` asks on exactly
that settings edit shape (any change to `hooks` or `enabledPlugins`), so there is a backstop;
the instruction still stands.

## Concurrent sessions

Each interactive session gets its own working tree (2026-09-28): `EnterWorktree`/`claude
--worktree` creates a linked worktree under `.claude/worktrees/<name>/` (gitignored), torn down
via `ExitWorktree`/`git worktree remove` when the session ends — this replaces the old
one-tree-for-everyone model, which needed manual path-claiming discipline to avoid stepping on a
peer's uncommitted edits. What's still shared across every worktree of this repo, and still needs
discipline:

- **The memory store is one shared directory, not per-worktree.** `scripts/_lib/memory-dir.py`
  resolves the same encoded key from every worktree (keyed off `--git-common-dir`, not
  `--show-toplevel`), so `hooks/stop/memory-audit-commit.sh` serializes its own commit across
  concurrent sessions via an atomic lock — see the script's own header for the lock protocol.
- **A subagent shares its parent session's worktree**, not a worktree of its own — the same
  stage-by-path discipline still applies to it (`gate:bash:subagent-git-guard` denies a bare
  `stash`/`reset`/`clean`; verify `git diff --cached --name-only` before committing). **Opt-in
  exception (2026-09-28):** a builder dispatch that already trips Rule 13's validator requirement
  may instead get its own worktree, merged back only on a clean validator pass —
  `docs/reference/spawn-brief.md`'s "Isolated checkout dispatch" section. Not the default; the
  shared-worktree-plus-discipline model above still applies to every other dispatch.
- **`ListAgents`/`SendMessage` file-claim discipline** (`~/.claude/CLAUDE.md`, injected globally)
  still applies to anyone touching a file another live session might also touch — worktree
  isolation removes the *working-tree* collision, not a collision in a file both sessions read
  from or write to outside git (e.g. the shared memory store above).
- **Leave the version alone in a PR.** `scripts/merge-pr.sh` cuts it at merge time, under its
  merge lock, from `origin/develop`'s number (see Merging above), so a PR's title, body and commit
  messages never name a version. Bumping it yourself only brings back the manifest conflict on
  every peer merge. The lock also keeps two PRs from cutting the same number, which left the
  installed cache with whichever tree built first (#492 and #493 both took 1.1.189, #496 and #497
  both took 1.1.191, 2026-10-05).
- **`/rewind` only reverts this session's own worktree.** It can no longer touch a peer's tree at
  all, since each session now has its own — this constraint from the old shared-tree model is
  gone, not merely mitigated.
