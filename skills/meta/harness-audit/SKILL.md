---
name: harness-audit
description: "Deterministic structural audit of the plugin's agents, skills, and hooks. Use when asked to audit the harness or check drift. Don't use for repo lint."
model: inherit
effort: medium
---

# Harness Audit

Runs every check under `scripts/checks/` over `agents/`, `skills/`, and `hooks/` and reports CRIT / WARN / INFO.
Exit code = CRIT count; WARN and INFO never change it.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/audit.sh"            # full run
bash "${CLAUDE_SKILL_DIR}/scripts/audit.sh" --only 22  # one check by number
```

## What it checks

| Area | Checks |
|---|---|
| Loadability | 02 skills, 03 agents (plugin cache or symlink) |
| Frontmatter | 04 agents (name, description, bucket enum), 05 skills (name, description, bucket dir, trigger clause), 21 `model:` is a documented alias, 28 strict YAML, 54 model + effort present |
| Names | 07/08 name matches filename, 23 lowercase-hyphen format |
| Agent tool grants | 09 explicit `tools:`, 10 no duplicates, 24 real tool tokens, 41 never `Agent`, 32 reviewers stay read-only |
| Hooks | 11 no orphaned hook files, 22 hooks.json event / type / matcher validity, 33 `${CLAUDE_PLUGIN_ROOT}` not `CLAUDE_PLUGIN_DIR`, 73 hooks.json / hook-registry.json id-registry drift |
| Bundled files | 17 python compiles, 18 shell parses, 19 JSON parses |
| Descriptions | 20 <= 1536 chars each, 29 no imperative injection words, 43 cumulative listing budget, 77 <= 25 words + third-person voice |
| Doc rot | 35 script pointers in prose resolve, 42 reference files carry no leaking frontmatter, 79 pinned prose facts (gate/skill/agent counts, README gate table, this check table, manifest versions) match the tree, 80 `mh:`/`mattpocock-skills:`/`codex:` skill references in prose resolve, 81 reference files over 100 lines carry a Contents heading |
| Working tree | 70 stray top-level entries (gitignored clutter), 71 paired Codex plugin's review-gate state, 72 spawn-brief's Codex `--effort` set vs the installed plugin |
| Gates and manifests | 74 subagent-scoped gates keep their `agent_id` presence check, 75 `mh:<skill>` references match `plugin.json`'s shipped skills, 76 measurement-coverage status freshness, 78 every nested skill is covered by a `plugin.json` skills entry and no `marketplace.json` entry declares `skills` |

Vendor-validated limits (1536-char descriptions, hook event set, model aliases, name format) are
WARN, not CRIT: vendor docs lag features, so an unrecognized value is flagged for a human.

## Plugin delivery

Components load from `~/.claude/plugins/cache/<marketplace>/mh/<version>/`; the audit picks the
highest installed version. `--plugin-cache <path>` overrides it (the `known-bad/` fixtures use
it); `MH_CACHE_DIR` overrides the cache root.

## Extending checks

Add `scripts/checks/NN-slug.sh` with a `# NN. <title>` header line. Call `crit`, `warn` or `info`;
never print your own summary. Add `NN` to `_exp_ids` in `audit.sh` in the same commit (the
integrity guard fails closed on a lost, duplicated or unlisted fragment). Pair it with a defect in
`tests/skills/harness-audit/known-bad/fleet-bad/` (`fleet-good/` stays silent) and an assertion in
`test-harness-audit.sh`, or a `check-NN-*` fixture pair when it needs its own tree. Avoid a
process spawn per file in a loop (`$(basename …)`, `| grep`): the audit runs on every commit, so
use parameter expansion or one batched call.

```bash
bash tests/skills/harness-audit/test-harness-audit.sh   # self-test, every check fires and stays silent
```

## Completion criterion

The audit ran to completion (a `=== Summary` block, not a crash) and every CRIT was either fixed
and confirmed by a clean re-run, or accepted with a written reason. Editing a file without
re-running is not done.

## Failure modes

- **Fixing without re-running.** A typo in the fix only shows up on the re-run.
- **Stale `--plugin-cache`.** A hand-passed old version brings back loadability CRITs.
- **Green because empty.** A check over a missing directory passes vacuously; a full run WARNs
  when `agents/`, `skills/` or `hooks/` is missing.
