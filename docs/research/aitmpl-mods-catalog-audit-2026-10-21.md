# aitmpl.com/mods catalog adoption audit (2026-10-21)

**Date:** 2026-10-21
**Source:** https://www.aitmpl.com/mods/, read 2026-10-21. The page is a client-rendered shell (raw HTML carries only the meta description), so its card list was read through a scraper (lossy, banner-marked, page 1 of 2 only). Primary evidence is the vendor repo `davila7/claude-code-templates`, shallow clone at commit `94f3d6d8dbb4b7b4353c5f9377b6cfc808a3b867` (2026-10-21), `cli-tool/components/mods/` plus `dashboard/public/components/mods.json`. No pinned release: the catalog installs from the moving `main` branch.
**Verdict:** Do not adopt any catalog mod into mh, and do not install one for the operator on this evidence. Keep the catalog as a feature feed: write the decline register, and turn at most two residual ideas (output-side secret redaction, a write guard for `.env`/lockfiles/workflows) into native proposals, each with its feasibility stated first. The catalog's descriptions are mostly accurate, but the mods are thin where it matters: the two security mods that look useful miss most of what they claim to cover, and the vendor's own scanner marks 16 of 45 mods DO_NOT_INSTALL, including 6 of 7 security mods.
**Score:** 49/100 — **FAIL** for adopting the catalog's mods (threshold 60; confidence medium). The blast-radius axis is below the 40% floor. Full criteria table: see Decision score below.

Every claim below about the source's internals is what it describes as of this read, not a verified fact about the source as it exists today or in the future.

## Method

Four agents, read-only. Agent A (claims) and Agent B (repo fit) ran in parallel and isolated, on `opus/high`. The attacker was meant to be Codex (`gpt-6.1-sol`, medium, read-only, schema-bound), but it hit its usage limit mid-run (resets 2026-10-22), so no result exists from it. Per the skill, the fallback was a `general-purpose` agent with the same brief: **independence reduced for this pass**. Its output passed `check-verdict.py` and `check-citations.py` (exit 0 both), and `git status --porcelain` was empty before and after. I re-ran its key finding myself (`irrecoverable.py` rule lines, below). The earlier same-catalog audit is `docs/research/external-sources-drilldown-2026-09-25.md` (section 2: `jev-model-router`, 5.0, don't adopt); this pass extends it to the whole catalog and re-checks that finding against version 0.4.2. A same-session `mh:ideate` run on this URL produced a shortlist (antibody memory, gap scan, declined-mods register); this audit supersedes two of its premises (see Correction to the ideate run). The source's page 2 was not read, and the saved source is a banner-marked extraction, so any claim resting only on it is graded `Author-asserted`.

## Claim-by-claim: the page is mostly accurate, the safety mods are thin

Legend: `MATCH` = claim confirmed against primary evidence · `PARTIAL` = partially confirmed · `GAP` = claim not found / contradicted by primary evidence · `N-A` = not applicable to this repo.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| 1 | "44 components" | Yes — observed directly | Clone has 45 mod dirs and 45 `mods.json` entries (15 games, 30 others); `stack-viewer` has 0 downloads and was scanned the same day, so the page is probably one build behind. | PARTIAL |
| 2 | Mods are on by default in CC 2.1.287+; install writes `.claude/skills/<name>/` | Install path: Yes — observed directly. Default-on: Author-asserted | Installer pulls from GitHub `main`, no pin (`cli-tool/src/index.js:1754`, `:1755`, `:1807`). Local CLI is 2.1.306. mh's own docs say the same minimum (`docs/reference/cost-ledger-module.md:127`). | MATCH |
| 3 | Secret Redactor redacts keys, tokens and connection strings in every tool result and refuses a placeholder in Bash | Yes — observed directly | Behaviour is real (`secret-redactor.ts:83-129`), fail-closed. It covers results only, never what the model sends, and 8 of 10 probes passed through (`.env` `KEY=value`, AWS secret key, base64, PEM without END, https/amqp URLs with credentials, `xoxe-`, `npm_`). A hook with no matcher that fails closed denies every tool call when it breaks. | PARTIAL |
| 4 | Block Destructive Commands denies recursive rm on roots, force push, hard reset, destructive SQL, disk format | Yes — observed directly | Default rules at `block-destructive-commands.ts:33-41` pass 13 of 13 probes through, among them `rm -rf /*`, `rm -rf ~/Documents`, `git push --force-with-lease ... --force`, `git push origin +main`, `find . -delete`, `git branch -D`. | PARTIAL |
| 5 | Protected Paths Guard denies Edit/Write/NotebookEdit on `.env`, lockfiles, CI workflows, git internals, keys | Yes — observed directly | Matcher is those three tools only (`protected-paths-guard.ts:60`); Bash writes (`>`, `sed -i`, `cp`) are not covered. | PARTIAL |
| 6 | Universal Audit Log "records every event" | Yes — observed directly | Default skip list has 7 events including `turn.step` (`universal-audit-log.ts:68`); strings cut at 200 chars; never records outputs; fail-open; the log sits where the agent can edit it. | PARTIAL |
| 7 | Prompt Cache Control: TTL follows Claude Code's rules (1 hour on a subscription, 5 minutes otherwise) | Yes — observed directly | `cache.ts:84-108` matches. Reads settings files, `~/.claude.json` (two keys kept) and env; no network calls. | MATCH |
| 8 | Session Time Machine writes a transcript copy under a new id | Yes — observed directly | True, and the page omits more: after every mutating tool call it runs `git add -A` and `update-ref` into `refs/time-machine/<session>/` (`snapshots.ts:54`, `:59`), including untracked non-ignored files, with no cleanup. | PARTIAL |
| 9 | Ultra Config writes settings after a backup copy; every activation can be undone | Yes — observed directly | One `.bak` overwritten each write; undo reverts only the last of 20; undo also overwrites keys changed after activation (`register.tsx:59,148,265`; `profiles.ts:337-347`). `~/.claude/settings.json` is a symlink into the dotfiles repo on this machine. | PARTIAL |
| 10 | Jev Model Router routes subagent models at `agent.spawn` | Yes — observed directly | Still overrides an agent's own model via `next({...e, model})` (`jev-model-router.ts:328`, `:335`; `types/claude-code.d.ts:300`). Earlier audit's finding holds in 0.4.2 except the word "silently": decisions are logged, never refused. | MATCH |
| 11 | admin-capability-lockdown withholds `$.http`/`$.process` from other plugins | Yes — observed directly (as the vendor's `.d.ts` declares it) | Real only when seated in managed prepend; binds only plugins beneath it; `$.fs` is not withheld (`admin-capability-lockdown.ts:42`). Its default would refuse mh's own module (`hooks/mod/cost-ledger.ts:34` calls `$.process.run`). | PARTIAL |
| 12 | Every card carries a "NVIDIA SkillSpector Scanner" label | Yes — observed directly | `mods.json` `skillspector`: 16 DO_NOT_INSTALL, 29 CAUTION, none clean, all 45 `analysis: partial`. Sampled findings are pattern matches on README lines and test fixtures (`secret-redactor.test.ts:15`), so the label is neither a pass seal nor a reliable alarm. | PARTIAL |
| 13 | Download counts (2,813; 1,715; 1,652; 302; 144; 101) | Yes — observed directly | All six match `mods.json`; 35 of 45 mods have fewer than 50 downloads. | MATCH |
| 14 | aitmpl install "runs the fixed CLI argv" | Yes — observed directly | The argv is `npx claude-code-templates@latest` (`productivity/aitmpl/hooks/catalog.ts:179`), unpinned. | PARTIAL |
| 15 | Third-party data flows | Yes — observed directly | `websearch-to-exa` sends the query to api.exa.ai; the five `jev-*` mods send prompt text to api.typesafe.ai or the Vercel gateway; `jev-vercel-sandbox` also uploads the git-listed workspace to api.vercel.com. | N-A for adoption (they confirm the earlier rejection) |

## Shipped

Nothing in the product. This is a read-only research pass; the one repo change is this file, left uncommitted because `develop` is PR-only.

## Deliberately not shipped

- **Install `secret-redactor` for the operator** — `secret-redactor.ts:35-46` (8 of 10 probes missed) and `:83`, `:112-129` (matcher-less, fail-closed) **and** METHODOLOGY Rule 1 (blast radius: a broken redactor denies every tool call) with the vendor scanner at DO_NOT_INSTALL. Labeled: **declined on evidence**.
- **Port `block-destructive-commands` rules into mh** — `hooks/gates/irrecoverable.py:2072-2074` (`mkfs`), `:2355-2356` (`dd-device`), `:2362-2364` (`sql-drop`) **and** the composer-not-creator doctrine (the rules already exist, and the mod's list is weaker). Labeled: **premise dead**. Agent B's claim that these were uncovered was wrong; the attacker caught it and I re-ran the grep.
- **A deny or rewrite module owned by mh** — `docs/reference/cost-ledger-module.md:133-134` ("one module per plugin", "never a gate") **and** `docs/reference/operating-model.md` section 1 plus `CLAUDE.md` ("never a new PreToolUse gate"). Labeled: **deferred** until output-rewrite by shell hook is shown to be impossible (see Open questions).
- **A cache-TTL meter in mh** — `hooks/stop/cost-tracker.sh:393-395` already records cache read/write tokens, and the live countdown is an operator display, not a harness need **and** YAGNI. Labeled: **deferred**.
- **Jev Model Router / Skill Suggestion** — `docs/research/external-sources-drilldown-2026-09-25.md:65-69` (5.0) and `docs/research/jev-adoption-revisit-2026-09-20.md` **and** METHODOLOGY Rule 14 (stated score, prior verdict stands). Labeled: **declined on evidence** (fifth consecutive round).
- **Publishing mh into the catalog** — no demand on file, and a copy drifts from the plugin cache **and** YAGNI. Labeled: **deferred**.
- **Using the catalog CLI at all** — `~/.claude/docs/tooling-notes.md:67` forbids `npx ...@latest` (it names the aitmpl catalog), and the CLI writes untracked plugin code into the cwd **and** the supply-chain posture in that file. Labeled: **declined on evidence**.

## Decision score (METHODOLOGY Rule 14)

Decision scored: adopt (install or ship) the catalog's mods. Pass threshold 60 (mh's 6/10 bar), fatal-weakness floor 40% of each axis's own max.

| Criterion | Weight | Score | Reason |
|---|---|---|---|
| primary-source-fidelity | 40 | 7/10 | Largest weight, as the skill requires. Anchors: 3 = descriptions contradicted by the code; 8 = descriptions match the code with minor overclaims. Here 5 of 15 claims are MATCH or N-A and 10 PARTIAL: "44", "every event", and "fixed argv" overclaim, and the safety mods cover far less than their titles. Nothing is contradicted. |
| fit | 30 | 4/10 | Weighted second: whether mh has the need decides adoption. Anchors: 3 = no need; 8 = a verified uncovered need with a clean landing spot. One real gap exists (secret redaction of tool output, and a write guard for `.env`/lockfiles/workflows), but mh cannot land it as a module or a gate, and a shell-hook route is unverified. |
| blast-radius-reversibility | 30 | 3/10 | Same weight as fit: cost if adopted and wrong. Anchors: 3 = third-party code with fs/http/process, unpinned `@latest`, fail-closed matcher-less hooks that can deny every call; 8 = observer-only, pinned, removable by deleting a directory. Mods are removable, but while running they sit on every session, and the vendor's own scanner says DO_NOT_INSTALL for 16. |

Weighted sum: (7×40 + 4×30 + 3×30) / 10 = (280 + 120 + 90) / 10 = **49.0/100** (script: `total 49.0`, `primaryWeightOk true`). Pass threshold 60; `blast-radius-reversibility` is below the 40% floor (3 < 4), so the floor trips independently. **FAIL.** Confidence: medium (two isolated analysts plus one fallback attacker whose independence is reduced; the Codex pass did not run; page 2 and the game mods were not read; one fit question is unverified).

## Open questions

- Can a shell `PostToolUse` hook replace a built-in tool's output? Agent B marked this unverified and nothing in the repo, memory or `~/llm-wiki` settles it — revisit only by reading Claude Code's hooks reference or probing it from a main session, not by more reading of this catalog.
- The page shows 44, the repo has 45, and page 2 of the listing was not extracted — revisit only if the catalog count matters to a future decision.
- Is the third-party mod `plannotator` registering a `tool.call` hook? Agent B asserted it; the attacker could not confirm it without reading the plugin cache — revisit only if the operator wants a full inventory of mods already running here.
- Whether `$.fs`/`$.process` calls made by a mod bypass the operator's PreToolUse guards (inferred, not tested) — revisit only if a mod is ever installed.

## Correction to the ideate run (same session, 2026-10-21)

The `mh:ideate` run on this URL assumed the mod format was new to mh and proposed adopting one pinned mod (Secret Redactor) as a candidate. Both premises are wrong: mh already ships a mod (`hooks/mod/cost-ledger.ts`, one module per plugin, observer only), and Secret Redactor is the vendor's own DO_NOT_INSTALL pick with 8 of 10 probes missed. The ideate shortlist's other two items (a decline register, a gap scan) survive; the adopt-one idea does not.

**Correction (2026-10-22, deep-audit of this session):**

- **Open question 1 is answerable.** `.claude-plugin/types/claude-code/index.d.ts:1256` declares `hookSpecificOutput.updatedToolOutput` for a classic (settings/command) `PostToolUse` hook, "replaces what the model sees of the tool's result"; `updatedMCPToolOutput` (`:1261`) is the MCP-only variant. These are the engine's declarations (Claude Code 2.1.289), not a live probe. So the "fit" reason (4/10) and the "deferred until output-rewrite by shell hook is shown to be impossible" item are weaker than written: output-side redaction probably has a native shell-hook route, and `CLAUDE.md:57` bans only a new PreToolUse gate. The score is not re-run; a probe from a main session is the next step.
- **Shipped section is stale.** The file was committed in `c27435fe` and merged by PR #531 (`bb9e399b`), not left uncommitted.
- **Claim 15:** the clone has six `jev-*` mods, not five.
- **Citation:** "never a gate" sits at `docs/reference/cost-ledger-module.md:135`; "one module per plugin" at `:133`.
- **Open question 3 settled:** `plannotator` registers a `tool.call` hook (`hooks/mod/register.ts:377` in its plugin cache).

<!-- Reserved: a later pass appends a further dated correction here, never rewrites the sections above. -->

