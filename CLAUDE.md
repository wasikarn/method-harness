# CLAUDE.md

Map only: each rule's history and mechanics live in the named `docs/reference/` file.
`docs/METHODOLOGY.md` is injected whole at session start.

## Validation (run before committing)

```bash
bash skills/meta/harness-audit/scripts/audit.sh   # 0 CRIT required; the structural gate
bash scripts/run-gauntlet.sh                       # plugin-validate, lint, every test under tests/
```

pre-commit: staged lint, home-path ban, audit, 4096-byte cap on `docs/METHODOLOGY.md`, gate canary.
pre-push: the gauntlet. There is no CI, so these two local hooks are the only gates; branch
protection requires a PR, no status checks. Detail: `docs/reference/repo-gotchas.md`.

## Composer-not-creator

Before writing a new skill or agent, check `mattpocock-skills`, then `codex@openai-codex`, then
the other local harnesses, in the order `docs/reference/composer-not-creator.md` gives. Create a
native surface only when none fit.

## Authoring

Skills follow `mattpocock-skills:writing-for-agents`; descriptions are at most 25 words, third
person (`docs/reference/skill-authoring-conventions.md`, `docs/reference/agent-authoring-conventions.md`).
Routing questions: `/mattpocock-skills:ask-matt`. Issues: GitHub Issues on `wasikarn/method-harness`
via `gh`. Domain docs: root `GLOSSARY.md` plus `docs/adr/` (`mattpocock-skills:domain-modeling`);
mh requires upstream's optional ADR `status:` frontmatter (`proposed`/`accepted`/`deprecated`/
`superseded by ADR-NNNN`); revisit at ~6 files in `docs/adr/` (frozen `docs/research/` ADRs excluded).

## Research: check qmd before web search

Search configured `qmd` collections first (`qmd status`), then `context7` for library docs, then
`WebSearch`. Verify technical claims before shipping them into agent or skill content.

## Branching and architecture

`develop` is protected: PR only, from a `feat/`/`claude/` branch, reviewed via
`mattpocock-skills:code-review`; `scripts/merge-pr.sh` refuses a PR whose last verdict comment is not
`Fresh-context review: MERGE @ <reviewed sha>`. Branches never bump the manifests: `merge-pr.sh` syncs
develop and bumps at merge time. No `gh` (cloud): `sync-pr-head.sh`, then `merge-pr.sh --verify`, then the
MCP merge pinned to the head. Worktrees, the shared memory store: `docs/reference/branching-model.md`.
Ships as `mh@wasikarn` from the plugin cache; design: `docs/reference/operating-model.md`; env
vars: `docs/reference/env-vars.md`; the one hooks module: `docs/reference/cost-ledger-module.md`.

## Non-obvious gotchas (bodies: `docs/reference/repo-gotchas.md`)

- **Keep `core.hooksPath` relative** (`git config core.hooksPath git-hooks`): an absolute path silently runs zero hooks after a rename; verify `test -d "$(git config core.hooksPath)"`.
- **Home paths:** `$HOME` or `~` in every committed file, never `/Users/<name>` or the bare account name; frozen dirs (`docs/research/`, `docs/post-mortems/`, `docs/plans/`, `CHANGELOG.md`) skip style sweeps, never this.
- **Use `trash` and stage by name;** `gate:bash:irrecoverable` denies `rm -rf`, `--no-verify`, and `git add -A`/`.` outside a merge.
- **Same-version edits are no-ops:** bump both manifests locally (uncommitted) before `claude plugin update`; re-verify a same-session edit by `Read`ing the repo path, never `Skill(<name>)`.
- **Bare `grep` is Claude Code's shell-snapshot shim** (it reformats output): use `/usr/bin/grep` or `awk` for counts.

## Repeated mistake -> doctrine

A mistake that recurs (a feedback memory firing again, or seen twice in-session) becomes a
committed rule here or in `docs/reference/`, since memory is per-operator and can go unread.
Better, a check: an audit check, gauntlet test, or lint (never a new PreToolUse gate,
`docs/reference/operating-model.md` §1) that fails on the real past mistake, fails only when a
change adds more of the pattern (a ratchet), and replaces the prose rule once it covers it.
