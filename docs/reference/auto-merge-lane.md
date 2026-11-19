# Auto-merge lane

Label-gated auto-merge for low-risk PRs. The runner is `scripts/merge-lane.sh` in the dotfiles repo; its header comment and code are the source of truth for every check, so this page only says what a PR author needs to know. No model makes the merge decision.

## What an author needs to know

- A human adds the label `lane:auto`; that label is the per-PR authorization, and an agent never applies it. Add it after the last commit: a commit with a committer date newer than the label refuses the PR. (The runner compares committer dates, which a deliberate actor can forge; the head-SHA pin still binds the merge to what was checked.)
- The PR must target `develop`, be authored by the owner, be mergeable, and stay under the line, file and commit caps in the script.
- Every changed path must be on the allowlist and none on the denylist (below). A path on neither list is refused.
- The runner re-runs the gauntlet in a clean worktree of the PR head and asks a read-only Codex run for a verdict. Only a clean pass can merge; it can add a refusal but never override one.
- A refusal comments the reason and removes the label. A transient problem on one PR (network, mergeable `UNKNOWN`, a timeout) defers it: the label stays for the next run.

## Paths

Allowed: `docs/*`, `*.md`, `skills/*/references/*`.

Denied: `hooks/*`, `scripts/*`, `agents/*`, `.github/*`, `.claude-plugin/*`, `*SKILL.md`, `*CLAUDE.md`, `*AGENTS.md`, `rules/*`, `*/rules/*`, `*settings*`, `*.env`, `*.env.*`, `*secret*`, `*credential*`, `*.pem`, `*.key`, `*id_rsa*`, `*hooks.json`. The denylist is checked first, so it wins.

`tests/*` is not on the allowlist, so a test script is refused: the gauntlet executes the tests with the owner's HOME before any verdict exists. A Markdown file under `tests/` still passes through `*.md`.

## Try it without merging

`merge-lane.sh --dry-run` runs every check and writes nothing to GitHub.
