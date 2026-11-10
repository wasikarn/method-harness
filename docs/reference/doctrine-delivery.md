# Doctrine delivery: why it stays a SessionStart hook

`docs/METHODOLOGY.md` reaches a session through `hooks/session/doctrine-bootstrap.sh`. It was weighed against
native Claude Code rules (`~/.claude/rules/*.md`) filled by a setup skill that copies rule files out of the plugin.
The hook stays. Decision of 2026-11-10, from an `mh:attack-proposal` pass (two attacker lanes, two validator rounds).

## Why not rules

- Plugins cannot ship rules. The plugin reference lists no `rules` component, ignores a plugin-root `CLAUDE.md`, and
  documents no way for a plugin to add files to `~/.claude/rules/`. A copy step would be a workaround of our own.
- The hook is the only path that reaches every place mh runs. A Claude Code on the web session installs the plugin
  from `scripts/cloud-setup.sh` and has no `~/.claude/`. An eval run uses its own config dir with no `rules/`: the
  with-plugin arm gets `<doctrine>` from the hook and the no-plugin arm gets nothing, which is what the Rule 1, 4
  and 13 cases compare. With the hook gone, both arms would see no doctrine.
- A copy goes stale: `scripts/merge-pr.sh` bumps the version on every merge, and the copy does not follow. It also
  outlives the plugin (disable or uninstall leaves doctrine that cites gates which are gone), lands as an untracked
  file in the dotfiles repo, and can overwrite the operator's own rule files through the `~/.claude/rules/` symlinks.
- A shell `cp` into global context is not seen by `global-context-guard.py`, which covers Write and Edit only.
- A setup skill that only copies files cannot clear the blind A/B bar in `CLAUDE.md`, so it would have to be a plain
  script anyway.

## What the hook gives up

- No `/memory` listing and no native reload from disk. Neither is needed: the doctrine group has no matcher, so the
  hook runs on startup, resume and clear and again after compaction (`docs/reference/cost-baseline.md`).
- Subagents do not receive it. All eight subagents of the session that made this decision held no `<doctrine>` block
  and no `~/.claude/rules/` file, so native rules would not have reached them either (n=8, one session; not measured
  beyond that). Delivery to a subagent is the spawn brief (Rule 13, `docs/reference/spawn-brief.md`).
- It stays under the 10,000-character `additionalContext` cap with room to spare (3,471 bytes with the doctrine).

## What the hook now says when it fails

If `docs/METHODOLOGY.md` cannot be read (a partial plugin cache, an unset `CLAUDE_PLUGIN_ROOT`) the script prints
`<!-- mh:doctrine-missing -->` with the path it tried, instead of nothing, so a session without doctrine says so.
`tests/hooks/test-doctrine-bootstrap.sh` pins it.

## Reopen only on new evidence

A reason to revisit: Claude Code lets a plugin ship rules, or the eval runner copies user rules into its sandbox.
