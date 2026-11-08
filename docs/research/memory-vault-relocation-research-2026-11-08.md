# Relocating Claude auto-memory into a single "Memory" vault (research, 2026-11-08)

Status: research input for `/mh:idea-audit`, not a decision. Author: the host session; every probe below was designed and run by the same session, so none is independently checked yet.

## The idea

Keep `MEMORY.md` as an index only (a book's table of contents). Move the full memory files out of `~/.claude/projects/<enc>/memory/` into one vault, "Memory", with one folder per project, so qmd and Obsidian see all projects in one place. The vault is separate from `~/llm-wiki`.

## Claims

C1. Claude Code docs (`code.claude.com/docs/en/memory`): `autoMemoryDirectory` relocates auto memory; needs v2.1.234+ [corrected 2026-11-08: added in 2.1.74; 2.1.234 is the version for `CLAUDE_CODE_PROJECT_DIR_NAME`]; readable from user, project, local, policy or `--settings` scope; value must be an absolute path or start with `~/`. (Extracted with a Firecrawl query, lossy.)
C2. Docs: MEMORY.md loads each session as "first 200 lines or 25KB"; topic files are read on demand; memory files are excluded from the `cleanupPeriodDays` sweep.
C3. Probe 1 (`claude -p --model haiku --settings '{"autoMemoryDirectory": <scratch dir>}'`): with a scratch folder holding `MEMORY.md` (pointer line with token ZEBRA-7741) and a topic file (token OTTER-9902), the model quoted both. Result: index and topic file load from a vault-style folder.
C4. Probe 2: `MEMORY.md` in one folder with an absolute-path pointer to a body file in a different folder; the model quoted the far token HERON-3318. Result: bodies can live outside the memory directory.
C5. Probe 3: asked to save a feedback memory with the setting pointing at the scratch folder, the model wrote `probe-write-works.md` there and added a pointer line to `MEMORY.md`. Result: writes follow the setting.
C6. Probe 4: `~/.claude/projects/<enc>/memory` replaced by a symlink to a scratch folder, no setting; the model quoted LYNX-5521 from the index. Result: a symlink works and covers every worktree that derives the same `<enc>`. The probe's project folder was trashed afterwards.
C7. Token cost: MEMORY.md is 15,220 B (59% of the 25,600 B cap, 109 lines) with 509 top-level files; in the 2026-08-07 baseline it was 19,402 B for 178 files. Start-up cost depends on index size, not on where the bodies live.
C8. `~/llm-wiki/CLAUDE.md` says Claude Code's per-project auto-memory holds session/workflow meta for one repo, domain knowledge belongs in the wiki and is never duplicated there; `~/.claude/docs/tooling-notes.md` says wiki writes are operator-driven (`/wiki-ingest`, `ingest.sh`). So the vault must not be `llm-wiki` itself.
C9. Breakage list: `memory-file-recall.py` (dotfiles) finds the memory dir as `dirname(transcript)/memory` (line 39), so a relocated store silently drops out of recall; `user-memory-redirect.py` and its tests name the path; qmd collections `mh-memory` and `dotfiles-memory` point at the old folders. The mh resolver `scripts/_lib/memory-dir.py` already honors `autoMemoryDirectory` and has a nudge test.
C10. 12 projects have a memory dir; the largest are method-harness (537 entries), dotfiles (286), tathep (211), amplitube-presets (145).

## Extension (operator, 2026-11-08): book model and three layers

X1. Book model: `MEMORY.md` is the table of contents with main chapters and sub-chapters. The store already has this shape: `MEMORY.md` (109 lines) has a "Sub-indexes" section linking `index-cc-mechanics.md` (64 entries), `index-settled-audits.md` (72) and `index-gate-work.md` (26); those link topic files.
X2. Three layers mapped onto the book: hot = `MEMORY.md` (loaded every session, first 200 lines or 25KB); warm = sub-indexes and topic files (read on demand through a pointer); cold = archived and vault material found by qmd search (`_archive/` holds 27 files; qmd indexes the store as `mh-memory`).
X3. Prior art in the operator's own wiki: `llm-wiki/wiki/ai-agents/knowledge-context/three-tier-memory-architecture.md` (hot = claude-mem, warm = QMD, cold = wiki-central) is marked SUPERSEDED; a banner says the hot/warm/cold framing was replaced by Episodic / Semantic / Index. Letta/MemGPT use core / recall / archival (third-party blogs and the MemGPT paper abstract).
X4. Probe 5 (host-run): `MEMORY.md` links a chapter index in a subfolder, which links a section file; with `autoMemoryDirectory` set, the model followed two hops and quoted the leaf token FALCON-6603. Result: a 3-level index works for the model.
X5. Cost of depth: each hop is one more Read; the sub-indexes (about 22.9 KB together) are not loaded at start, so depth keeps start-up cost flat while retrieval costs extra tool calls.

## Benefits claimed

One qmd collection instead of two (cross-project search), one folder to back up or put under git, Obsidian graph across projects.

## Risks claimed

A worktree or clone without the per-project setting writes to the old default folder (split-brain); the symlink avoids that. Two dotfiles hooks need a fix first. A mass move breaks wikilink stems and qmd paths if done wrong. Not tested: a move of a real store, git history of the store, symlink behavior across a Claude Code update.

## Reproduce

Probes: create a folder with a `MEMORY.md` pointer line holding a unique token, run `claude -p "quote the token from your auto memory index" --model haiku --settings '{"autoMemoryDirectory":"<abs path>"}'` from an empty scratch directory.
