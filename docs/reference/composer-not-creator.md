# Composer-not-creator doctrine

Before writing a new skill or agent from scratch, check sources in this order:

1. **`mattpocock/skills` first.** What is installed under the `mattpocock-skills@mattpocock`
   plugin (`claude plugin list`, namespaced `mattpocock-skills:<name>`), plus the local clone
   at `~/Codes/Personals/mattpocock-skills` if this machine has it, for what is upstream but not
   yet installed. This is a Matt-Pocock-first harness; checking ECC or superpowers before
   matt's own repo gets the priority backwards. If the clone exists, `git fetch` it before
   trusting it: the installed plugin can be newer than the clone (it silently lagged
   `origin/main` by a full minor release once).
2. If installed: `codex@openai-codex`, for anything the task needs from a second, independent
   coding agent rather than a new mh surface — `docs/reference/codex-integration-map.md`.
3. If present: `~/Codes/Personals/ECC` and `~/Codes/Personals/superpowers`.
4. If present: sibling harnesses under `~/Codes/Personals/` for structural patterns.

Cherry-pick and adapt from whichever fits; create a native surface only when none do. Skipping
step 1 has collided with matt's own work before (2026-07-17: a `code-implementer` agent built
against ECC and superpowers duplicated `/mattpocock-skills:implement`; the user caught it, not
the checklist). None of the `~/Codes/Personals/` clones ship with the plugin; on a machine
without them, the installed plugins are the only source.

A clone reached via `claude --add-dir` loads none of its own CLAUDE.md by default; set
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` if you need its instructions, not just its files.

## Headroom pilot

A new skill, agent or workflow is built only if bare Claude leaves room to beat it. Run the pilot first:

- Cases written by an agent that never saw mh.
- Bare Claude only, with mh disabled: `claude plugin eval --ablation none`, without the
  `with_default_enabled_true` wrapper.
- The decision rule written and the graders' hash recorded before the run.

Build only if bare Claude scores 0.85 or lower on a case; otherwise report "no headroom" and stop. A case that
qualifies then goes to the operator's blind A/B keep-bar. Operator decision of 2026-11-12: bare Claude passed most
blind cases mh tried, though not all (`evals/README.md`).

## Which mattpocock skill routes where

`docs/reference/mattpocock-integration-map.md` tracks, per installed `mattpocock-skills` skill,
whether mh routes to it, defers, or ships its own surface instead — re-check it before adding a
new touchpoint so a second one doesn't drift from the first.

## Vetting a third-party plugin or skill

A skill gives Claude new capabilities through instructions and code, so treat installing one
like installing software. Before relying on a new plugin, MCP server, or skill: read its
SKILL.md and scripts once for the network calls, file writes, and Bash commands it can trigger,
and confirm they match its stated purpose.
