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
- `git-hooks/pre-push` refuses a direct push whose remote ref is `refs/heads/develop`, before the
  gauntlet even runs — local, defense-in-depth, one manual retry if a stdin ref line is malformed.
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
  There is no CI (2026-10-03): the pre-commit and pre-push hooks are the only gates, so a clone with
  `core.hooksPath` unset, or a push from another machine, skips them. Re-add a workflow and the
  required contexts together if that stops being acceptable.

## Merging: `scripts/merge-pr.sh <PR>` (GH #450)

#445 and #446 were each green alone and red together on `develop`. Agents merge through
`scripts/merge-pr.sh <PR>`, not bare `gh pr merge`. It runs `git fetch origin`, refuses unless the
PR's base is `develop` (re-read just before the merge) and its review verdict (below) says MERGE,
waits for load below 4 (default 900s, then fails with the load figure), fetches again and syncs the
head when it lacks the `origin/develop` tip or a version above it (below), then checks ancestry
(`git merge-base --is-ancestor`), the review again, and versions (plain `X.Y.Z`, both manifests equal,
above `origin/develop`'s; `MERGE_PR_ALLOW_SAME_VERSION=1` accepts an equal version, for a PR that needs
no bump; an unreadable manifest or a failed fetch also refuses, with a message naming it), merges with
`gh pr merge --merge --match-head-commit <checked sha>`, and prints the merge commit sha. On a
wrong-base refusal, retarget the PR with `gh pr edit <PR> --base develop`.

**Branches do not bump the version; the merge does.** While every branch bumped its own manifests,
develop's version moved 48 times in six hours (2026-10-25) and each open PR re-merged and re-bumped
after every one (#618 took five rounds). Now, after the load wait, a head that lacks `origin/develop`
or does not ship a version above it goes to `scripts/sync-pr-head.sh <branch> <head>`: in a temporary
worktree it merges `origin/develop` (a manifest conflict takes develop's side only when the branch
changed nothing in that manifest but its version line; any other conflict, including a manifest edit
next to the version line, refuses, so merge develop into the branch yourself and push), sets both manifests to
develop's version + 1 (or the branch's own when it is higher: a deliberate minor bump survives) in
one manifest-only commit, and pushes to the PR branch, leased on the head. That push runs the pre-push
gauntlet on the exact tree that will merge, and fails if the branch moved since the head was read. The gauntlet
takes minutes and develop can move meanwhile, so `merge-pr.sh` fetches and syncs again, up to
`MERGE_PR_SYNC_TRIES` rounds (default 3), then merges pinned to the synced head; a PR from a fork
cannot be pushed to and is refused instead. A rebase rewrites every commit, so it also throws away
the review verdict below; the sync never rebases.

It also refuses a PR without a current review verdict (2026-10-25: #569–#576 and #611 merged while
their reviews still said FIX FIRST, and #570 opened a hole that took #602 to close). The verdict is a line
`Fresh-context review: MERGE @ <sha>` (or `FIX FIRST` / `CLOSE`; case and markdown emphasis ignored) in a
PR **comment**, `<sha>` being the head the reviewer read; a GitHub PR review or the PR body does not count,
nor does a line inside a ``` or ~~~ fence at any indentation (closed only by a bare line of the same
character, at least as long), and the last verdict line in a comment wins. The last verdict on
the PR must be `MERGE`, its `<sha>` must be in the head's history, and every commit after it must touch only
the two manifests or be a two-parent merge whose tree is what `git merge-tree --write-tree` makes of its parents,
manifests aside, and whose only conflicts were in the manifests (GH #629; git >= 2.38), checked before and
after the load wait. So merging `develop`
and bumping the version keep the review; any other change (an edit made inside a merge, or a conflict
resolved in code, included), a rebase, or a force-push needs a new one. The
check is bound to the sha, not to timestamps, so a commit made before the review but pushed after it is
still caught. Post the reviewer's result as that comment. It proves a verdict was posted, not who wrote it
or that the reviewer had fresh context. There
is no opt-out variable; an operator who must merge without a verdict does it on GitHub.

**Without `gh` (a Claude Code cloud session).** The script reads the PR and merges through `gh`, which a
cloud session lacks; it has the GitHub MCP tools instead. Do not retype the checks by hand (that was
done for #633, #644 and #648, with nothing to say a check was skipped). Instead:
1. read the PR's head sha, base branch and issue comments with the MCP tools, and save the comments
   (the JSON array they return) to a file;
2. if the head lacks `origin/develop` or a version above it, run `scripts/sync-pr-head.sh <head branch>
   <head sha>` and use the sha it prints;
3. run `scripts/merge-pr.sh --verify <PR> <head sha> <base branch> <comments file>`: the same base,
   review (same verdict parser), ancestry and version checks, never a sync, push or merge. It prints
   the head on a pass, and on a head that is not synced it names the sync command;
4. merge through the MCP merge tool with `expectedHeadSha` set to that head, straight away. If develop
   moved first, go back to step 2.
There is no load wait in this mode: a cloud container runs nothing else.

The checks are local-only. The script narrows the gap; it does not close it: a push to `develop`
from another clone between the check and the merge can still race, and nothing stops a merge made
outside the script. The script's own `gh pr merge` call runs inside the script, so
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
  from or write to outside git (e.g. the shared memory store above; the manifests are per
  checkout, which is why `merge-pr.sh` reads the version from `origin/develop`).
- **Do not bump the manifests on a branch.** `scripts/merge-pr.sh` gives the PR the next version
  at merge time (Merging above), so the number is read from `origin/develop` seconds before the
  merge instead of hours before it. Merge only through the script (never bare `gh pr merge`): two
  PRs that cut the same version leave the installed cache with whichever tree built first, and the
  other change does not load until the next bump (#492 and #493 both took 1.1.189, #496 and #497
  both took 1.1.191, 2026-10-05). A branch that does bump (a deliberate minor release) keeps its
  number when it is above develop's.
- **`/rewind` only reverts this session's own worktree.** It can no longer touch a peer's tree at
  all, since each session now has its own — this constraint from the old shared-tree model is
  gone, not merely mitigated.
