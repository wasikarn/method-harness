# Proposal: one "Memory" vault, book-style index, three layers (revision 3)

**Status: NO-GO for the migration** (2026-11-08, after 3 validator rounds). The migration step never closed. The lint and nudge defects found along the way shipped on their own in PR #959; leftovers are GH #960. See `## Correction note` at the end, which wins over the text above where they disagree.

## The problem

Claude Code auto-memory is split over 22 non-empty stores in `~/.claude/projects/<enc>/memory/` (19 real projects, 1,493 .md files, about 4.97 MB, 3,430 wikilinks). The largest, method-harness, has 510 top-level files with a `MEMORY.md` of 15,220 B (59% of the 25,600 B cap). The operator wants one vault ("Memory", separate from `~/llm-wiki`) with one folder per project, `MEMORY.md` kept as a table of contents with chapters and sub-chapters, and an explicit hot/warm/cold layering. Measured today: only 60% of topic files are within 2 hops of `MEMORY.md` (308 of 509); 14 have no link path; no memory backup exists; only 2 of 22 stores are git repos.

## The change

1. Vault: `~/Memory/` (an Obsidian vault) holds `~/Memory/<project-slug>/` per project, each with `MEMORY.md` (hot), `index-*.md` chapter indexes and topic files (warm), and `_archive/` (cold). Work projects (tathep, entronica) sit under `~/Memory/_work/<project-slug>/`.
2. Mechanism: replace each `~/.claude/projects/<enc>/memory` directory with a symlink to its vault folder. A script `memory-vault-link.sh` does it per project: copy, verify file count and hashes, then swap, keeping the old directory under a dated name until the operator deletes it. The store's `.git` and its hooks move with the folder. No `autoMemoryDirectory` setting is used.
3. Book contract, enforced by a new memory-lint check: `MEMORY.md` lists chapters (links to `index-*.md`) plus pinned entries and stays at or under 60% of both caps; every topic file is reachable within 2 hops of `MEMORY.md`; headings and one-line hooks are plain text written by the author, with no generated summaries.
4. Layers: hot = `MEMORY.md`; warm = chapter indexes and topic files; cold = `_archive/` plus search (qmd BM25/vector and grep). Moving a file down to `_archive/` stays with the existing memory-lint action-mode classes A-D. No new usage-based eviction rule until a read log has about 4 weeks of data.
5. qmd keeps one collection per project, now pointing at the vault folders. There is no vault-wide collection (it was tried on 2026-05-19 and split back on 2026-05-21).
6. Rollback: delete the symlink and move the folder back.
7. Order: phase 0 adds the lint depth check and links the 201 topics deeper than 2 hops and the 14 with no link path (no move); phase 1 pilots one small project (llm-wiki's own store, 21 files); phase 2 migrates the rest. Phase 1 and 2 need the operator's go-ahead per project. Fixing the stale llm-wiki page (a real `superseded-by` target) is an operator step, since wiki writes are operator-driven.

## Must stop

- Writes landing outside the vault after cutover (split-brain). Example: a new git worktree of a migrated project, or a session started with a different `CLAUDE_CONFIG_DIR`, writing to a real `memory/` directory that now sits beside or replaces the link.
- Data loss in migration. Example: a live session in the same project saves a memory between the copy and the swap, and the new file exists only in the old directory; or the mh and tathep stores' git history is dropped by the move.
- `MEMORY.md` crossing 200 lines or 25 KB so the tail is silently not loaded. Example: the book-style index adds chapter lines on top of 83 pointers and reaches 201 lines.
- Work memory leaking: a tathep or entronica memory appearing in a personal-project qmd query, or the vault being pushed to a remote that mixes both.
- Memory becoming an agent-write path into `~/llm-wiki` (its rule: auto-memory is per-repo workflow meta, wiki writes are operator-driven).
- `type: user` memory written into a project store because `user-memory-redirect.py` no longer matches the symlinked path.
- A missing or unmounted vault making sessions start with no memory and no warning (dangling link).

## Must allow

- A session in any worktree of a migrated project writes a new memory file and sees it in the next session.
- `memory-file-recall.py`, `memory-health-nudge.sh`, `memory-lint.py` and `memory-audit-commit.sh` keep working from the current directory.
- qmd queries filtered to one project, and Obsidian opening the vault.
- One-command rollback of a single project.
- A project that has not been migrated keeps working unchanged.

## Known facts

Verified:
- `autoMemoryDirectory` in `--settings`, `.claude/settings.json` and `.claude/settings.local.json` was honored by `claude -p --model haiku` (host probes: tokens ZEBRA-7741, HERON-3318, MOLE-4410 from both project and local scope). Scope: `-p` mode, one machine, CC 2.1.319.
- A symlinked `memory/` directory is read through (probe LYNX-5521) and a 3-level index (index, chapter index, section file) is followed by the model (probe FALCON-6603). Writes follow `autoMemoryDirectory` (probe `probe-write-works.md`).
- Store stats, depth table and layer counts: Agent B's report from this session (own link count, may differ from memory-lint; lint reported 0 findings).
- Prior work: `docs/research/agent-memory-proposals-audit-2026-11-08.md` (49.5/100 FAIL for per-entry tokens, use-driven eviction and a history/fact split); GH #95 closed wontfix ("Deterministic memory relevance scoring (top-k injection)"); GH #100 closed ("SessionStart injection budget"); PR #464 and issue #328 made the nudge honor `autoMemoryDirectory`; dotfiles commit `3a86a0bd` (2026-05-21) split the all-projects qmd collection per project; `~/llm-wiki/CLAUDE.md:11` keeps auto-memory out of the wiki.
- Docs say `MEMORY.md` loads "first 200 lines or 25KB" (Firecrawl extraction of code.claude.com/docs/en/memory, fetched 2026-11-08).

- Primary docs (R1, fetched live 2026-11-08, code.claude.com/docs/en/memory and settings reference): MEMORY.md loads "first 200 lines ... or the first 25KB, whichever comes first"; topic files "read on demand"; an over-limit write succeeds but Claude Code returns an error telling Claude to rewrite the index (2.1.210); frontmatter and HTML comments are not counted (2.1.211); all worktrees of one repo share one memory directory; subagents do not get the main conversation's auto memory; `autoMemoryDirectory` (added 2.1.74) is "read from any settings scope" and from project or local settings "under the same workspace trust rule as hooks"; with `permissions.blockReadsOutsideWorkingDirectories` on, a directory chosen by the project's `.claude/settings.json` is neither loaded nor written (2.1.273); `CLAUDE_CODE_PROJECT_DIR_NAME` (2.1.234+) fixes the `<project>` directory name; auto memory cannot be turned on from a background or nested session (2.1.285); memory content is sanitized on load (2.1.284).
- Dangling-link probe (host, `claude -p --model haiku`, CC 2.1.319): with `~/.claude/projects/<enc>/memory` a symlink to a path that did not exist, Claude Code created the target directory and wrote `dangling-probe.md` plus a new `MEMORY.md` there, with no error. A missing vault folder is silently recreated empty.
- The operator's wiki (R4): `llm-wiki/wiki/ai-agents/knowledge-context/three-tier-memory-architecture.md` is superseded, and the page it names as replacement ("memory architecture integration plan") does not exist; the 2026-04-18 debate record (`llm-wiki/raw/ai-agents/knowledge-context/memory/2026-04-18-memory-architecture-tabula-rasa-debate.md:105-109`) ends in "do nothing more", an active two-tier setup (Semantic = wiki, Index = qmd) plus session JSONL, git, hotcache and `MEMORY.md`, and its "do not re-evaluate before 2026-10-18" window has lapsed. claude-mem is not installed (`~/.claude-mem` absent; no match in `installed_plugins.json`); `~/wiki-central` does not exist.
- Research (R3, arXiv abstracts read through the Firecrawl index, not the arXiv pages): a deterministic summary tree with no LLM calls ties the strongest flat baseline (2610.06902); agent-driven lexical search recovers most of the benefit of elaborate memory structures (ReFind, id not captured); decay helps perishable facts and reverses on stable ones (ScrubJay-MEM, id not captured); no controlled head-to-head of usage-based versus recency eviction was found; none of the 2025-26 abstracts isolates core/recall/archival tiers.

- Prior art (R2, official docs and repos fetched 2026-11-08): no memory system documents "hot/warm/cold" naming. Letta MemFS (docs.letta.com/concepts/memfs): a git-backed memory filesystem where files at the memory root are loaded into the prompt every turn and directories with their own `MEMORY.md` stay out of context until needed, with a frontmatter description per file; this is the same table-of-contents shape as the proposal. Letta's background "Dreaming" consolidates with git history as the safety net. Mem0 treats decay as a search-time ranking bias, "never a filter". Zep/Graphiti invalidate facts with validity windows and delete nothing. claude-mem and Letta both pair a small always-loaded index with on-demand detail; Mem0 and Graphiti preload nothing. (The ~800-token index and 35,000-token figures are a docs example, not a measurement.)

Unverified:
- The 2.1.319 binary also contains the setting description "Enable background memory consolidation (auto-dream)". What it consolidates, where, and whether it rewrites `MEMORY.md` or topic files in a symlinked or vault folder is not known; it is not in the docs pages R1 read.
- Whether the 2.1.319 binary string "Ignored if set in projectSettings (checked-in .claude/settings.json) for security" (Agent B) is stale or refers to the `blockReadsOutsideWorkingDirectories` case; the docs and the `-p` probe say project scope is honored. Interactive-session behavior with a trust prompt is untested.
- Whether a Claude Code update replaces or rewrites a symlinked `memory/`.
- Whether `user-memory-redirect.py:321` and `memory-file-recall.py:39` behave through the link in a live run (read, not run).
- Research (abstract-level, third-party aggregator found some ids): deterministic tree/TOC navigation ties flat retrieval (arXiv 2610.06902); lexical agent search recovers most of the benefit of elaborate memory (ReFind, id not captured); decay helps perishable facts and hurts stable ones.

## Revision 1

Eight breaks confirmed (each reproduced by the host on a scratch fixture or by reading the cited code) and one accepted. Where this section and "The change" disagree, this section wins.

- B1 (damage, race): a live session writes after the hash check but before the swap, so the new file exists only in the old directory. Closed: the link script refuses while a Claude Code process has that project as its cwd; it takes the store's commit lock; it renames the old directory to `memory.pre-vault-<date>` and installs the link as one step, then runs a second `rsync -a --update` from the renamed directory into the vault and re-verifies counts and hashes; if a real `memory/` directory reappears at the path before the link lands, the script stops and merges it. The renamed directory is kept at least 30 days.
- B2 (damage, config): a session started with another `CLAUDE_CONFIG_DIR` or `CLAUDE_CODE_PROJECT_DIR_NAME` resolves memory outside the link. Accepted, not closed: this is how memory behaves today, since a different config directory is a different store by design. The link script refuses to run when either variable is set in its environment, lists other `projects` roots it finds, and the migration notes say the vault covers only the default config directory.
- B3 (damage, silent recreate): a missing vault folder is recreated empty by Claude Code and `memory-health-nudge.sh:84` exits quietly. Closed: each vault folder holds a `.vault-id` file written by the link script; `memory-health-nudge.sh` warns loudly when `memory` is a symlink whose target is missing or lacks `.vault-id`; the vault lives on the internal disk (not removable storage). Reproduced: the dangling-link probe.
- B4 (bypass, hook): `user-memory-redirect.py` matches `<home>/.claude/projects/<project>/memory/<file>.md` only, so a `type: user` write through the vault path (Obsidian, an agent working inside `~/Memory`) is not denied; through the link path it is denied (reproduced both). Closed: add a second scope pattern for `<vault root>/<project>/<file>.md`, the vault root set by `MEMORY_VAULT` (default `~/Memory`), plus tests. It only widens what is denied. A dotfiles hook edit, so T3 and it waits for the operator.
- B5 (bypass, hook): `memory-health-nudge.sh:93` runs `find "$MEMDIR" -maxdepth 1 -type f -newer` on the link itself, which lists nothing, so a clean lint cache is never invalidated (reproduced: 0 files through the link, 1 through the real path). Closed: resolve `MEMDIR` with `realpath` before the `find`, with a symlinked-fixture test in `tests/hooks/test-memory-health-nudge.sh`.
- B6 (bypass, lint): a chapter pointer hidden in an HTML comment makes `MEMORY.md` look clean (reproduced: lint prints "clean") while the loaded index lacks it. Closed: pointer extraction strips HTML comments the same way the budget measure does; test added.
- B7 (over-block, lint): a chapter index in a subfolder (`chapters/index-a.md`) produces STALE POINTER and UNINDEXED (reproduced, exit 2), since lint reads only top-level files and drops link targets containing `/`. Dropped from the proposal: chapter indexes stay flat `index-*.md` files beside `MEMORY.md`, as they are today; the vault folders stay flat too. The depth check treats a subfolder target as an error.
- B8 (bypass, demotion): Class D's guard (`memory-lint.py:587`) compares reachable sets, not distance, so deindexing a pinned pointer can leave a topic 3 hops deep and break the 2-hop contract. Closed: Class D skips any candidate whose removal pushes any topic past 2 hops, and never deindexes an `index-*.md` pointer; test with a fixture where the oldest file has a 3-hop backup path.

Order after revision: phase 0 is the lint and nudge fixes (B5, B6, B8, the depth check, the B3 warning), each a failing test first; they fix defects that exist today and need no vault. Phases 1 and 2 (pilot, then the rest) stay gated per project on the operator, because the earlier audit found need weak.

## Revision 2

Validator round 1 returned OPEN on B1 and B4 and two NEW breaks; the host reproduced NEW-1 and NEW-2 on a scratch store (Class A moves `x.md`, leaves the pointer `_archive/2026-11-08/x.md`, and lint then prints `STALE POINTER ... but file missing`, exit 2). Where this section and earlier text disagree, this section wins.

- B1 (reopened): the link is made under a temporary name beside `memory` and installed with `os.rename(tmp_link, memory)` (rename(2)); it never uses `ln -s` or `ln -sfh` onto the path, since the validator showed both silently nest the link inside a recreated real directory. If the rename raises `IsADirectoryError` (a real `memory/` reappeared between the directory rename and the link), the script stops, merges that directory's files into the vault with `rsync -a --update`, moves the directory to `memory.pre-vault-<date>.late`, and retries once. The refusal while a session is running is best-effort only: it lists `claude` processes with `lsof -a -d cwd -c claude` and compares each cwd's git common dir to the project's; the guarantee comes from the second rsync and the temp-link rename, not from the refusal. (BSD `pgrep` hides its own ancestors, so the script's own session is not counted.)
- B2 (doc gap): the script also refuses when `autoMemoryDirectory` is set in any settings file the resolver reads (`./.claude/settings.local.json`, `./.claude/settings.json`, `~/.claude/settings.json`) or in `~/.claude/settings.local.json`; it names that third store in the migration notes.
- B3 (build conditions): the symlink check sits before `memory-health-nudge.sh:84` and before the clean-cache exit at `:93`, tests `-L` itself (since `-d` is false on a dangling link), then tests the `.vault-id` sentinel. SessionStart runs synchronously, so the warning reaches the model before its first turn; whether Claude Code creates the directory before hooks run is unprobed, and the sentinel test answers correctly either way.
- B4 (reopened): the vault scope is `<vault root>/(_work/)?<project>/<file>.md`, with `<project>` required not to start with `.` (so `.obsidian/` and top-level notes stay allowed); `MEMORY.md` keeps its basename exemption. Tests are the validator's corpus (`b4-corpus.txt`) plus a `_work` row. T3 (dotfiles hook), the operator decides.
- B6 (build hazard): comments are stripped only in the pointer-extraction step (the `referenced` set), never from `state["idx"]`, because `apply_action_plan` writes `idx` back; a test checks that a comment block in `MEMORY.md` survives `--auto-archive --yes`.
- B7 (condition): the depth check has its own extraction step that reports a link target containing `/` as an error; `md_link_target` stays as it is.
- B8 (second clause): Class D never deindexes an `index-*.md` pointer; test with a fixture where the oldest entry is a chapter index.
- NEW-1 (Class A breaks the 2-hop contract): Class A gets the same hop-distance guard as Class D: it skips archiving a superseded file when the move would leave any topic more than 2 hops deep, and never archives an `index-*.md`. Test: the validator's `ba-fixture`.
- NEW-2 (Class A stub fails lint, a defect today): lint's STALE POINTER check accepts a pointer whose target exists under `_archive/`; a test applies Class A to a fixture and requires lint to report no STALE POINTER. This is a prerequisite for using `_archive/` as the cold layer, so it goes first in phase 0.

## Revision 3

Validator round 2 returned OPEN on B1 and NEW-2 and five NEW items; the host checked each against the validator's own reproduction output (the move-first ordering, the `lsof` process name, the depth stub, the composed guards, the comment scan, the fswatch path). Where this section and earlier text disagree, this section wins.

- B1(a) (a write between the merge and the `.late` move): the order becomes move first. If `os.rename` raises `IsADirectoryError`, the script first renames the recreated real directory to `memory.pre-vault-<date>.late`, then installs the link, then merges `.late` into the vault with `rsync -a --update`, so no write can land in a directory the final rsync does not read.
- B1(b) (an index line lost when both sides edited `MEMORY.md`): after the final `rsync -a --update`, the script compares `MEMORY.md` by pointer lines, not by hash: any pointer line present in the old directory's `MEMORY.md` and missing from the vault's is appended to the vault's `MEMORY.md`. If the post-swap verify still differs on any other file, the script leaves both directories in place, exits non-zero and prints the one-line rollback; it never deletes the old directory, which is kept at least 30 days.
- B1(c) (the session check never matches): Claude Code processes show as COMMAND `2.1.319`, not `claude`. The check lists `lsof -a -d cwd` rows whose command is `claude` or matches `^[0-9]+\.[0-9]+\.[0-9]+$`, and compares each cwd's git common dir to the project's. It stays best-effort; live sessions are the normal case here, so the procedure above is built to survive them, and the migration notes ask the operator to close that project's sessions first.
- NEW-2 (open): the depth check exempts a target that exists under `_archive/`, with the same acceptance as the stale-pointer check; the test requires `memory-lint.py` to exit 0 after Class A applies to a fixture that has no other findings.
- NEW-3 (A and D guards not composed): Class D evaluates its hop guard on the graph after Class A's plan is applied (files and pointers minus plan A), and Class B's collapse gets the same guard, since a collapsed line can drop the only pointer to a topic (also true today); test: validator fixtures `fxAD` and `fxBM`.
- NEW-4 (comment stripping lets Class D delete commented lines): Class A, B and D candidate scans use the comment-stripped index; writes keep the raw index; test with a store at 87% of the cap whose `MEMORY.md` holds a comment block with pointers (`fxD6`): after `--auto-archive --yes` the comment block is byte-identical.
- NEW-5 (qmd goes stale after the move): the link script ends by repointing `index.yml` and restarting the fswatch launchd agent (`launchctl kickstart -k` on its label), then checks that a new file in the vault produces an fswatch event. A T3-adjacent step (launchd job), so the operator runs it.
- NEW-6 (archived stubs stay in the hot index): accepted as a known residual. Each stub is about 100 B; lint already reports NEAR-BUDGET and the 60% target applies. No Class E is added (YAGNI).
- Depth contract as a ratchet: the real store has 200 topics deeper than 2 hops (the mh store), so the check starts as a count plus the 5 deepest, never one line per file, never failing; it fails only when a change adds more deep topics than the stored baseline. It skips files that are already unreachable, so UNINDEXED and TOO DEEP do not repeat each other. Ship it with or after the relink, not before, because the nudge prints the whole lint output every session.
- Presence-only `.vault-id` (a link aimed at another project's vault folder passes): accepted as residual, since it needs a script bug, not a session; the script writes the project slug into `.vault-id` and the nudge compares it with the slug it derives from the resolver.

## Correction note (2026-11-08, after PR #959 merged)

This record was written before its outcome was known. Where it disagrees with this note, this note wins.

**Verdict.** The attack-proposal ended NO-GO for the vault migration. Validator round 3 failed (`pass: false`), so the fault is in the plan, not the patch.

**Still open (these block any migration):**
- B1(a)/(b): the live-directory swap while sessions may be running. `rsync -a --update` overwrites a vault file written in the same second, and the pointer-line union of `MEMORY.md` drops headings and edited lines. Claude Code processes show as `2.1.319` in `lsof`, so a process check for `claude` never matches. Untested alternative: rename the directory itself into the vault on the same filesystem (atomic, no copy phase), then install the link with a temp link plus `os.rename`.
- The depth-contract ratchet's baseline spec (see Revision 3). It should ship with or after a relink, because the nudge prints the whole lint output every session.
- B3's `.vault-id` warning and NEW-5 (qmd and fswatch repointing) need a vault and were not built.

**Closed by PR #959 (merged into develop, mh 1.1.582), no vault needed:**
- B6/NEW-4: Class A, B and D scan the comment-stripped index and edit only outside HTML comments; a pointer that exists only inside a comment no longer counts as indexed.
- NEW-2: lint accepts a Class A `_archive/<date>/<file>` stub while that file exists.
- NEW-1, NEW-3, B8: Class A, B and D skip any change that strands a topic or pushes one past 2 hops, judged on the index the earlier classes leave (`build_plan`); `index-*.md` is never archived or deindexed.
- B5: the nudge's cache `find` follows a symlinked `memory/`. It shipped as a trailing slash on `"$MEMDIR/"` (`hooks/session/memory-health-nudge.sh`), not as the `realpath` this document says.
- Left for GH #960: Class C plans on the raw state, so it can point a link at a file Class A archives in the same run; `_pick_ledger_target`'s ledger fallback never matches.

**Numbers.**
- `autoMemoryDirectory` was added in Claude Code 2.1.74. 2.1.234 is the version for `CLAUDE_CODE_PROJECT_DIR_NAME`, not for this setting.
- The file counts in this record (509 and 510) are snapshots of the same store taken while memories were being written; memory-lint counted 510 memory files (excluding `MEMORY.md`) at the time. Of 509 topics, 308 are within 2 hops, so 201 are not (the "200" in Revision 3 is rounded). Those 201 include the 14 with no link path at all, so 187 are reachable but deeper than 2 hops. Step 7 of `## The change` ("the 201 topics deeper than 2 hops and the 14 with no link path") therefore counts those 14 twice: they are among the 201, not on top of them.

**Identifiers.** `B1`-`B8` are the breaks the Codex attacker lanes found (bypass, over-block, damage). `NEW-1`-`NEW-6` are breaks the validator found in its own rounds. Here `R1`-`R4` are the four research streams of the redesign. The sibling audit document `agent-memory-proposals-audit-2026-11-08.md` uses `R1`-`R4` for repo claims instead. Fixture names (`fxAD`, `fxBM`, `fxD6`, `ba-fixture`, `b4-corpus.txt`) are scratch files from the validator rounds that were not committed.
