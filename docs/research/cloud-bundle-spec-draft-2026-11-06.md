> **Superseded 2026-11-06, not built.** The cloud probe showed that a setup script which installs and enables the plugin runs mh in a web session, gates included, which disproves this draft's premise. The operator chose the setup script (`scripts/cloud-setup.sh`) over this bundle. Evidence: `mh-cloud-probe-2026-11-06/probe-results.md`.

## Problem Statement

The operator runs mh as a plugin locally, where its gates (irrecoverable commands, secret content, config writes, subagent git use, test integrity) and its doctrine protect every session. Claude Code on the web does not install plugins: a repo's `enabledPlugins`, user plugins and (for a public marketplace repo) account-synced plugins all fail to load. A web session in the operator's own repos therefore runs unattended with none of mh's protection and none of its doctrine. The web does load a repo's committed hooks, rules, skills and agents, but mh's source is written for a plugin (plugin-root paths, `mh:` names, `$HOME` state), so it cannot simply be copied.

## Solution

One source tree ships two ways: the existing plugin, and a generated **cloud bundle** that a repo commits under its own `.claude/`. A repo that carries the bundle gets, in a single-repo web session, the five core gates enforced by hooks, the doctrine as a rules file, and a small set of skills and agents. Local plugin behaviour does not change. In an unattended run the operator opts in to stricter behaviour with `MH_UNATTENDED=1`: gate asks that nobody can answer become denies that name the next step.

## User Stories

1. As the operator, I want the irrecoverable-command gate to run in a web session, so that an unattended agent cannot run `rm -rf`, a force push or `git add -A`.
2. As the operator, I want the secret-content gate in a web session, so that a pasted credential is stopped before it is written.
3. As the operator, I want the config-write gate in a web session, so that an agent cannot edit the repo's `.claude/` settings or the bundle itself.
4. As the operator, I want the subagent git guard in a web session, so that a subagent cannot stash, reset or stage everything.
5. As the operator, I want the test-integrity gate in a web session, so that weakening a test to get a green run is flagged.
6. As the operator, I want mh's doctrine loaded at the start of a web session, so that the agent applies the same decision rules as locally.
7. As the operator, I want the web doctrine to stay inside the same size cap, so that it does not crowd the context.
8. As the operator, I want a short web variant of the doctrine, so that it does not cite Codex, spawn briefs or skills that do not exist there.
9. As the operator, I want ask decisions to become denies only when I set `MH_UNATTENDED=1`, so that an interactive web session keeps its prompts.
10. As the operator, I want every deny to say what to do next, so that an unattended run reports the blocked step and goes on.
11. As the operator, I want local gate decisions to be byte-identical before and after this work, so that no one-way-door gate is weakened.
12. As the operator, I want a garbled or missing mode setting to fall back to local behaviour, so that a typo never switches a gate off.
13. As the operator, I want a session-start notice when python3 is missing, so that I know the gates are inactive instead of assuming they are on.
14. As the operator, I want the bundle to be a committed copy reviewed in a pull request, so that a gate change is a visible diff.
15. As the operator, I want a version and tree-hash stamp in the bundle, so that I can see which mh build a repo carries and detect drift.
16. As the operator, I want one command that syncs the bundle into a target repo, so that updating many repos is not manual copying.
17. As the operator, I want the sync to merge into a repo's existing settings, so that the repo's own hooks survive.
18. As the operator, I want running the sync twice to change nothing the second time, so that re-syncs produce clean diffs.
19. As the operator, I want a manifest that lists exactly which gates, rules, skills and agents are in the bundle, so that scope is explicit and checkable.
20. As the operator, I want gate scripts copied together with every sibling file they need, so that a missing helper never fails open or closed by accident.
21. As the operator, I want a test that fails when the bundle copy is incomplete, so that I find out before a web session does.
22. As the operator, I want the cost-ledger mod left out of the bundle, so that nothing writes outside the repo in the cloud image.
23. As the operator, I want hooks that write under the home directory to skip that work in a web session, so that no phantom state files appear.
24. As the operator, I want `mh:` prefixes rewritten in the bundle's skills and agents, so that references resolve without a plugin.
25. As the operator, I want a check that no `mh:` or plugin-root reference survives in the bundle, so that nothing dangles.
26. As the operator, I want a check that no home path of any user appears in the bundle, so that the public repo's hygiene rule holds.
27. As the operator, I want the web mode limited to single-repo sessions, so that I am not surprised when project threads skip repo hooks.
28. As the operator, I want a recorded probe of what the cloud environment provides (CLI present, python3, network, env vars), so that design assumptions rest on evidence.
29. As the operator, I want an ADR for the single-source decision, so that a future me knows why a generated copy exists.
30. As a future maintainer, I want a gauntlet test that exports the bundle and runs the gate canary against the exported hooks, so that a regression in the bundle fails the local gates.

## Implementation Decisions

- **Scope of the first bundle:** five gates (irrecoverable, secret-scan, config-write-guard, subagent-git-guard, test-integrity), a static doctrine rules file plus a short web variant, and the small set of skills and agents that need no plugin machinery. The three agent-workflow gates are portable but excluded from the first bundle because they have no use in a session without those events. The Codex and routine gates, all sensors, the memory features and the cost-ledger mod stay out.
- **Audience:** the operator's own repos, single-repo cloud sessions only. Project threads and multi-repo sessions skip repo hooks and are out of scope.
- **Root resolver:** one shared resolver for shell and Python derives the install root from the script's own location, with the existing plugin-root variables as overrides. All scripts that read a plugin-root variable move to it. The resolver tolerates a missing plugin manifest (version reads as unknown).
- **Mode helper:** one shared helper for shell and Python returns local or unattended. Unattended only when `MH_UNATTENDED=1`; any other value, a parse error or a missing helper means local. `CLAUDE_CODE_REMOTE` is used to skip home-directory writes, never to change a gate verdict.
- **State directory:** one resolver returns the state directory (home-based by default, project-based fallback). Hooks that write state under the home directory use it or return early in a web session.
- **Unattended verdicts:** in unattended mode the secret-content and config-write gates turn ask into deny with a message that names the next step. The test-integrity gate keeps ask. Every other verdict is unchanged. Local mode is unchanged and guarded by a regression test.
- **Hook generation:** a generator derives the bundle's hook entries from the plugin's hook definitions by registry id, replacing the plugin-root reference with the project-dir form. Hook entries are never hand-written. Exit-2 deny and the failure-handling key work the same for repo hooks as for plugin hooks (documented).
- **File set:** gate scripts are copied with every sibling they import. The irrecoverable gate needs its wrapper, decision script, runner, journal helper, brace-expansion helper and awk router; a missing runner or decision script makes that gate deny, so completeness is tested.
- **Manifest:** a bundle manifest under the hooks directory lists gates by registry id, rules, skills, agents and exclusions. A new audit check verifies every entry exists and every bundled skill is covered by the plugin manifest.
- **Namespace:** the export strips `mh:` prefixes from bundled skills and agents; the source stays in plugin form. A lint compares the rewrite against an allowlist so prose is not damaged.
- **Doctrine:** the full doctrine ships as a static rules file, byte-identical to the source; the web variant is under about 600 bytes and states the mode, a fallback for skills that do not exist, no Codex lane, and "an ask nobody can answer means skip and report". The existing size cap applies to the two files together.
- **Delivery:** a sync command writes the bundle into a target repo working tree for a normal pull request. No session-start fetch, submodule or release artifact. The bundle carries a stamp with the plugin version and a tree hash. The stamp is written by the sync command, not by the release script.
- **Session-start notice:** the existing portability preflight is reused; in web mode its wording says the gates are inactive and a destructive command should not be run. The session-start hook may try to install python3 where the image allows.
- **Trash hint:** the irrecoverable gate's deny hint stops assuming `trash` exists; the verdict is unchanged.
- **Record:** an ADR records the generated-copy decision. It is the sixth ADR, so the revisit threshold noted in the project instructions fires and is noted in the ADR.
- **Sequencing:** the operator first runs a probe in a throwaway cloud environment (setup script records CLI, python3, network and env facts). If installing the plugin from a setup script works, the scope shrinks; otherwise work proceeds as small pull requests: resolver and mode helper with the local-regression test; state directory; unattended verdicts; export and sync; web doctrine and notices; ADR and audit check.

## Testing Decisions

- A good test drives external behaviour: feed a gate the same JSON payload a hook would receive and assert the verdict and exit code. It does not assert internal structure.
- **One seam:** the exported hook command line. A gauntlet test exports the bundle into a temporary directory, reads the generated hook entries, and runs each command with the existing canary and differential payload corpora, in local mode and in unattended mode. This one seam covers completeness of the file set, path rewriting, the mode helper, the local-regression guarantee (local verdicts equal the plugin's) and the unattended deny rows.
- A second, thin seam covers the sync command: given a target repo with its own settings and hooks, sync preserves both, and a second run changes nothing.
- Static assertions in the same test: export is deterministic (two runs identical), no plugin-root reference, no `mh:` prefix and no user home path in the output, the doctrine copy is byte-identical to the source, the generated settings parse.
- Negative cases: garbled mode value behaves as local; a missing helper behaves as local; a bundle missing the runner or decision script makes the irrecoverable gate deny and the test report it.
- Prior art: the existing gate canary and differential scripts and their tests, the gauntlet wiring test, the audit checks for hook-registry drift and manifest coverage, and the session-start hook test for web-only behaviour.

## Out of Scope

- Making the plugin itself load in a web session (not supported by the platform; the probe only tests whether a setup script can install it).
- Account-synced plugins (need a private organization marketplace; mh is public).
- Project threads and multi-repo sessions.
- Sensors, the memory features, the cost-ledger mod, Codex pairing, routine triggers, and the agent-workflow gates in the first bundle.
- Bundling the audit, ideation and compliance skills and their agents.
- Any change to the release script or to how versions are cut.
- Fetching the bundle at session start.

## Further Notes

- Unknown until the probe runs in a real cloud environment: whether the CLI is on the path during a setup script, whether a hook ask is answered by a person in an interactive web session, the home directory's writability, and whether the env-file mechanism works at session start. The design does not depend on these except where noted above, and the mode switch is opt-in for that reason.
- Facts and sources are in the project memory note for this work and the cloud-environments documentation (what carries over from your setup).
