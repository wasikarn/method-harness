# Phase 2 — sandbox-caused gauntlet failures + scratch I/O

Moved verbatim from `SKILL.md` Phase 2 step 2. Read before writing the verifier's brief — the
verifier, not main, runs the base-SHA re-run below, so the brief must carry it.

- **A gauntlet failure can be caused by the sandbox itself, not the diff** (tests writing
  scratch state via `mktemp` outside the worktree fail under `workspace-write`). On any
  non-zero gauntlet exit, before reporting it as a finding: **the verifier itself** (never
  main, per the re-run rule in SKILL.md Phase 2) re-runs the identical gauntlet command at the plan's base
  SHA, in the same sandbox, **in a second, separate detached worktree pinned at the base SHA
  (`git worktree add --detach <second-path> <base-sha>`), removed after the re-run — never by
  checking out the base SHA inside the worktree already pinned at head**: that switch is a
  tracked-file change the before/after check (SKILL.md Phase 2) flags, and the head-pinned worktree the
  rest of Phase 2 uses stays untouched. Identical failure at base → pre-existing/environmental, not
  this diff's regression → return `NEEDS-DECISION` naming the specific failing test(s) and
  both exit codes, per `references/verifier-brief.md`'s existing escape hatch, rather than
  either a silent pass or an unexplained `DEVIATED`. Base SHA passes cleanly in the same
  sandbox → the failure is real, report it as a genuine gauntlet failure, no exception.
- **Don't redirect `TMPDIR`/scratch I/O into the worktree to "confine" it further** — the
  before/after tracked-diff check is the enforcement, and a temp dir inside a git repo breaks
  tests that assume otherwise (`tests/skills/memory-lint/test_memory_lint.py`'s not-a-git-repo
  test). Keep the normal temp-file defaults; only repo writes stay inside the worktree.
